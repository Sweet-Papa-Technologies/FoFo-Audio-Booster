#include "AudioDSP.h"
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>
#include <cstdlib>
#include <mach/mach_time.h>
namespace {
constexpr unsigned maxFrames=4096, maxSources=64, ringSize=32768, delaySize=2048, firSize=12;
static_assert(std::atomic<float>::is_always_lock_free && std::atomic<uint64_t>::is_always_lock_free);
float finite(float x) { return std::isfinite(x) ? x : 0.f; }
float rampTo(float value,float target,float coefficient) { float next=value+coefficient*(target-value);return std::abs(next-target)<1e-4f?target:next; }
float amplitude(float db) { return std::pow(10.f, db/20.f); }
struct Biquad {
    double b0=1,b1=0,b2=0,a1=0,a2=0,z1=0,z2=0;
    float run(float x) { double y=b0*x+z1; z1=b1*x-a1*y+z2; z2=b2*x-a2*y; return float(y); }
};
struct Plugin {
    AudioUnit unit=nullptr;
    std::atomic<bool> bypass{false};
    const float *left=nullptr, *right=nullptr;
    unsigned extraDelay=0, delayPosition=0;
    float delayed[2][maxFrames]{};
    float wet=1;
};
OSStatus pull(void *context, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32, UInt32 frames, AudioBufferList *data) {
    auto &p=*static_cast<Plugin*>(context);
    if (frames>maxFrames || data->mNumberBuffers!=2) return kAudioUnitErr_FormatNotSupported;
    for (unsigned c=0;c<2;++c) {
        data->mBuffers[c].mNumberChannels=1; data->mBuffers[c].mDataByteSize=frames*sizeof(float);
        const float *src=c ? p.right : p.left;
        if (data->mBuffers[c].mData) std::memcpy(data->mBuffers[c].mData,src,frames*sizeof(float));
        else data->mBuffers[c].mData=const_cast<float*>(src);
    }
    return noErr;
}
}
struct FFEngine {
    double rate;
    unsigned sources, offset, lookahead, position=0;
    bool analysisOnly;
    int32_t monitorSource=-1;
    float monitor[maxFrames]{};
    std::atomic<float> sourceDB[maxSources], masterDB{0}, ceilingDB{-1}, balance{0}, target{-14}, cap{12};
    std::atomic<bool> sourceMute[maxSources], mono{false}, loudness{false}, audible{true}, analysis{false};
    float sourceGain[maxSources], gain=1, pan=0, monoMix=0, ceiling=amplitude(-1), fade=0, limiter=1, makeup=1, ramp;
    float mixed[2][maxFrames]{}, scratch[2][maxFrames]{}, delay[2][delaySize]{}, history[2][firSize]{}, fir[4][firSize]{};
    float peakValues[delaySize]{};
    uint64_t peakIndices[delaySize]{}, sampleIndex=0;
    unsigned peakHead=0,peakTail=0;
    float samples[ringSize]{};
    std::atomic<uint32_t> write{0},read{0};
    std::atomic<float> reduction{0}, peak{0}, lufs{-100}, integrated{-100};
    double gatedEnergy[1400]{},absoluteEnergy=0;
    uint64_t gatedCount[1400]{},absoluteCount=0;
    std::atomic<uint32_t> failures{0}, pluginFailures{0};
    std::atomic<uint64_t> callbacks{0};
    Plugin plugins[8];
    FFBridge *remote=nullptr;
    Biquad shelf[2], highpass[2];
    double energies[30]{}, energy=0, energyTotal=0;
    unsigned energyFrames=0, energySlot=0, energyCount=0;
    double hostTickSeconds=0, renderSampleTime=0;
    FFEngine(double sr,unsigned n,unsigned off,bool only):rate(sr),sources(n),offset(off),analysisOnly(only) {
        lookahead=std::min(unsigned(std::ceil(sr*.0015)),delaySize-32);
        ramp=1.f-std::exp(-1.f/float(sr*.03));
        for (unsigned i=0;i<maxSources;++i) { sourceDB[i]=0; sourceMute[i]=false; sourceGain[i]=1; }
        mach_timebase_info_data_t tb; mach_timebase_info(&tb); hostTickSeconds=double(tb.numer)/tb.denom/1e9;
        for (unsigned p=0;p<4;++p) {
            double sum=0;
            for (unsigned k=0;k<firSize;++k) {
                double x=double(k)-5.5-double(p)/4;
                double sinc=std::abs(x)<1e-10 ? 1 : std::sin(M_PI*x)/(M_PI*x);
                fir[p][k]=float(sinc*(.5-.5*std::cos(2*M_PI*(k+.5)/firSize))); sum+=fir[p][k];
            }
            for (auto &v:fir[p]) v/=float(sum);
        }
        // BS.1770 K-weighting, bilinear transform at the actual device rate.
        double K=std::tan(M_PI*1681.974450955533/sr), Q=.7071752369554196;
        double Vh=std::pow(10.,3.999843853973347/20), Vb=std::pow(Vh,.4996667741545416), a=1+K/Q+K*K;
        for (auto &b:shelf) { b.b0=(Vh+Vb*K/Q+K*K)/a; b.b1=2*(K*K-Vh)/a; b.b2=(Vh-Vb*K/Q+K*K)/a; b.a1=2*(K*K-1)/a; b.a2=(1-K/Q+K*K)/a; }
        K=std::tan(M_PI*38.13547087602444/sr); Q=.5003270373238773; a=1+K/Q+K*K;
        for (auto &b:highpass) { b.b0=1; b.b1=-2; b.b2=1; b.a1=2*(K*K-1)/a; b.a2=(1-K/Q+K*K)/a; }
    }
    void publish(float sample) {
        if (!analysis.load(std::memory_order_relaxed)) return;
        auto w=write.load(std::memory_order_relaxed);
        if (w-read.load(std::memory_order_acquire)>=ringSize) return;
        samples[w%ringSize]=sample; write.store(w+1,std::memory_order_release);
    }
    void process(unsigned frames) {
        const float gainTarget=amplitude(masterDB.load()), panTarget=balance.load(), ceilingTarget=amplitude(ceilingDB.load());
        const float monoTarget=mono.load()?1:0, fadeTarget=audible.load()?1:0;
        const bool autoGain=loudness.load();
        float makeupTarget=1;
        float measured=lufs.load();
        if (autoGain && measured>-60 && energyCount>=4) makeupTarget=amplitude(std::clamp(target.load()-measured,0.f,cap.load()));
        for(unsigned f=0;f<frames;++f) {
            double e=0;
            for(unsigned c=0;c<2;++c) { mixed[c][f]=finite(mixed[c][f]); float k=highpass[c].run(shelf[c].run(mixed[c][f])); e+=double(k)*k; }
            energy+=e;
            if (++energyFrames>=unsigned(rate*.1)) {
                energyTotal-=energies[energySlot]; energies[energySlot]=energy/energyFrames; energyTotal+=energies[energySlot];
                energySlot=(energySlot+1)%30; energyCount=std::min(energyCount+1,30u);
                lufs.store(float(-.691+10*std::log10(std::max(energyTotal/energyCount,1e-10))));
                // BS.1770 integrated gating: overlapping 400 ms blocks, 100 ms hop,
                // -70 LUFS absolute gate then -10 LU relative to the absolute-gated mean.
                if(energyCount>=4) {
                    double blockEnergy=0;
                    for(unsigned j=0;j<4;++j)blockEnergy+=energies[(energySlot+30-1-j)%30]/4.;
                    double blockLUFS=-.691+10*std::log10(std::max(blockEnergy,1e-12));
                    if(blockLUFS>=-70) {
                        unsigned bin=unsigned(std::clamp(int(std::floor((blockLUFS+100)*10)),0,1399));
                        gatedEnergy[bin]+=blockEnergy;++gatedCount[bin];absoluteEnergy+=blockEnergy;++absoluteCount;
                        double gate=absoluteEnergy/double(absoluteCount)*.1,sum=0;uint64_t count=0;
                        for(unsigned i=0;i<1400;++i)if(gatedCount[i]&&gatedEnergy[i]/double(gatedCount[i])>=gate){sum+=gatedEnergy[i];count+=gatedCount[i];}
                        if(count)integrated.store(float(-.691+10*std::log10(sum/double(count))));
                    }
                }
                energy=0;energyFrames=0;
            }
            gain=rampTo(gain,gainTarget,ramp); pan=rampTo(pan,panTarget,ramp); monoMix=rampTo(monoMix,monoTarget,ramp);
            makeup+=(1.f-std::exp(-1.f/float(rate)))*(makeupTarget-makeup);
            float m=(mixed[0][f]+mixed[1][f])*.5f;
            for(unsigned c=0;c<2;++c) mixed[c][f]=(mixed[c][f]+monoMix*(m-mixed[c][f]))*gain*makeup*(c ? std::min(1.f,1.f+pan) : std::min(1.f,1.f-pan));
        }
        if(remote)ff_bridge_exchange(remote,mixed[0],mixed[1],frames);
        for(unsigned slot=0;slot<8;++slot) {
            auto &p=plugins[slot]; if(!p.unit) continue;
            float wetTarget=p.bypass.load()?0.f:1.f; if(wetTarget==0 && p.wet==0)continue;
            p.left=mixed[0]; p.right=mixed[1];
            struct StereoList { UInt32 count; AudioBuffer buffers[2]; } data{2,{{1,frames*4,scratch[0]},{1,frames*4,scratch[1]}}};
            AudioTimeStamp ts{}; ts.mSampleTime=renderSampleTime; ts.mFlags=kAudioTimeStampSampleTimeValid;
            AudioUnitRenderActionFlags flags=0;
            OSStatus status=AudioUnitRender(p.unit,&flags,&ts,0,frames,reinterpret_cast<AudioBufferList*>(&data));
            if(status!=noErr) { p.bypass.store(true); pluginFailures.fetch_or(1u<<slot); continue; }
            if(data.count!=2 || !data.buffers[0].mData || !data.buffers[1].mData || data.buffers[0].mDataByteSize<frames*4 || data.buffers[1].mDataByteSize<frames*4) { p.bypass.store(true); pluginFailures.fetch_or(1u<<slot);continue; }
            for(unsigned f=0;f<frames;++f) {
                p.wet=rampTo(p.wet,wetTarget,ramp);
                for(unsigned c=0;c<2;++c) {
                    float wet=finite(static_cast<float*>(data.buffers[c].mData)[f]);
                    if(p.extraDelay) {float previous=p.delayed[c][p.delayPosition];p.delayed[c][p.delayPosition]=wet;wet=previous;}
                    mixed[c][f]+=p.wet*(wet-mixed[c][f]);
                }
                if(p.extraDelay)p.delayPosition=(p.delayPosition+1)%p.extraDelay;
            }
        }
        renderSampleTime+=frames;
        float blockPeak=0, minLimiter=1;
        for(unsigned f=0;f<frames;++f) {
            float truePeak=0;
            for(unsigned c=0;c<2;++c) {
                float x=finite(mixed[c][f]); delay[c][position]=x;
                for(unsigned k=firSize-1;k>0;--k) history[c][k]=history[c][k-1]; history[c][0]=x;
                truePeak=std::max(truePeak,std::abs(x));
                for(auto &phase:fir) { float y=0; for(unsigned k=0;k<firSize;++k)y+=phase[k]*history[c][k];truePeak=std::max(truePeak,std::abs(y)); }
            }
            while(peakHead!=peakTail && peakValues[(peakTail-1)%delaySize]<=truePeak)--peakTail;
            peakValues[peakTail%delaySize]=truePeak;peakIndices[peakTail%delaySize]=sampleIndex;++peakTail;
            while(peakHead!=peakTail && peakIndices[peakHead%delaySize]+lookahead+firSize<sampleIndex)++peakHead;
            float windowPeak=peakValues[peakHead%delaySize];
            ceiling+=ramp*(ceilingTarget-ceiling);
            // Small reconstruction margin, followed by a bounded safety saturator.
            float wanted=std::min(1.f,ceiling*.97f/std::max(windowPeak,1e-10f));
            limiter=wanted<limiter ? wanted : limiter+(1.f-std::exp(-1.f/float(rate*.1)))*(wanted-limiter);
            fade=rampTo(fade,fadeTarget,ramp); minLimiter=std::min(minLimiter,limiter);
            unsigned r=(position+delaySize-lookahead)%delaySize;
            for(unsigned c=0;c<2;++c) {
                float x=delay[c][r]*limiter, knee=ceiling*.98f;
                if(std::abs(x)>knee) x=std::copysign(knee+(ceiling-knee)*std::tanh((std::abs(x)-knee)/(ceiling-knee)),x);
                mixed[c][f]=finite(x)*fade;blockPeak=std::max(blockPeak,std::abs(mixed[c][f]));
            }
            publish((mixed[0][f]+mixed[1][f])*.5f+monitor[f]); position=(position+1)%delaySize;++sampleIndex;
        }
        reduction.store(-20*std::log10(std::max(minLimiter,1e-10f)));peak.store(blockPeak);
    }
};
extern "C" {
OSStatus ff_configure_stream_usage(AudioObjectID device,AudioDeviceIOProcID proc,uint32_t tapStreams,bool analysisOnly) {
    for(auto scope:{kAudioObjectPropertyScopeInput,kAudioObjectPropertyScopeOutput}) {
        AudioObjectPropertyAddress streams{kAudioDevicePropertyStreams,scope,kAudioObjectPropertyElementMain};UInt32 bytes=0;
        OSStatus status=AudioObjectGetPropertyDataSize(device,&streams,0,nullptr,&bytes);if(status)return status;
        UInt32 count=bytes/sizeof(AudioStreamID);if(!count)continue;
        UInt32 size=sizeof(AudioHardwareIOProcStreamUsage)+(count-1)*sizeof(UInt32);
        auto *usage=static_cast<AudioHardwareIOProcStreamUsage*>(std::calloc(1,size));if(!usage)return kAudioHardwareUnspecifiedError;
        usage->mIOProc=reinterpret_cast<void*>(proc);usage->mNumberStreams=count;
        for(UInt32 i=0;i<count;++i)usage->mStreamIsOn[i]=scope==kAudioObjectPropertyScopeInput ? (i>=count-std::min(count,tapStreams)) : !analysisOnly;
        AudioObjectPropertyAddress property{kAudioDevicePropertyIOProcStreamUsage,scope,kAudioObjectPropertyElementMain};
        status=AudioObjectSetPropertyData(device,&property,0,nullptr,size,usage);std::free(usage);if(status)return status;
    }
    return noErr;
}
FFEngine *ff_create(double sr,uint32_t n,uint32_t off,bool only) { if(sr<8000||sr>192000||n>maxSources)return nullptr;return new(std::nothrow) FFEngine(sr,n,off,only); }
void ff_destroy(FFEngine *e){delete e;}
void ff_attach_remote(FFEngine *e,FFBridge *bridge){if(e)e->remote=bridge;}
void ff_set_source(FFEngine *e,uint32_t i,float db,bool muted){if(e&&i<e->sources){e->sourceDB[i].store(std::clamp(finite(db),0.f,24.f));e->sourceMute[i].store(muted);}}
void ff_set_master(FFEngine *e,float db,float ceiling,float balance,bool mono,bool loudness,float target,float cap){if(!e)return;e->masterDB.store(std::clamp(finite(db),0.f,24.f));e->ceilingDB.store(std::clamp(finite(ceiling),-12.f,-.3f));e->balance.store(std::clamp(finite(balance),-1.f,1.f));e->mono.store(mono);e->loudness.store(loudness);e->target.store(std::clamp(finite(target),-24.f,-9.f));e->cap.store(std::clamp(finite(cap),0.f,24.f));}
void ff_set_fade(FFEngine *e,bool b){if(e)e->audible.store(b);}
void ff_set_monitor_source(FFEngine *e,int32_t index){if(e)e->monitorSource=index;}
void ff_set_analysis(FFEngine *e,bool b){if(e)e->analysis.store(b);}
FFMeters ff_meters(FFEngine *e){if(!e)return {};return {e->reduction.load(),e->peak.load(),e->lufs.load(),e->failures.load(),e->callbacks.load(),e->pluginFailures.load(),e->integrated.load()};}
uint32_t ff_read_samples(FFEngine *e,float *dst,uint32_t cap){if(!e)return 0;auto r=e->read.load();auto n=std::min(cap,e->write.load(std::memory_order_acquire)-r);for(unsigned i=0;i<n;++i)dst[i]=e->samples[(r+i)%ringSize];e->read.store(r+n,std::memory_order_release);return n;}
OSStatus ff_attach_plugin(FFEngine *e,AudioUnit unit,uint32_t slot,bool bypass,uint32_t extraDelayFrames){if(!e||slot>=8)return kAudio_ParamError;auto &p=e->plugins[slot];p.unit=unit;p.bypass.store(bypass);p.wet=bypass?0:1;p.extraDelay=std::min(extraDelayFrames,maxFrames);AURenderCallbackStruct cb{pull,&p};return AudioUnitSetProperty(unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&cb,sizeof(cb));}
void ff_bypass_plugin(FFEngine *e,uint32_t i,bool b){if(e&&i<8){bool previous=e->plugins[i].bypass.exchange(b);if(previous&&!b)e->pluginFailures.fetch_and(~(1u<<i));}}
void ff_process(FFEngine *e,const float *l,const float *r,float *ol,float *orr,uint32_t n){if(!e||n>maxFrames)return;std::memcpy(e->mixed[0],l,n*4);std::memcpy(e->mixed[1],r,n*4);e->process(n);std::memcpy(ol,e->mixed[0],n*4);std::memcpy(orr,e->mixed[1],n*4);}
OSStatus ff_io_proc(AudioObjectID,const AudioTimeStamp *,const AudioBufferList *input,const AudioTimeStamp *,AudioBufferList *output,const AudioTimeStamp *,void *context){
    auto *e=static_cast<FFEngine*>(context);if(!e)return noErr;auto start=mach_absolute_time();e->callbacks.fetch_add(1,std::memory_order_relaxed);
    for(unsigned b=0;b<output->mNumberBuffers;++b)if(output->mBuffers[b].mData)std::memset(output->mBuffers[b].mData,0,output->mBuffers[b].mDataByteSize);
    unsigned frames=0,totalChannels=0;
    for(unsigned b=0;b<input->mNumberBuffers;++b){auto &v=input->mBuffers[b];totalChannels+=v.mNumberChannels;if(v.mData&&v.mNumberChannels)frames=frames?std::min(frames,v.mDataByteSize/(4*v.mNumberChannels)):v.mDataByteSize/(4*v.mNumberChannels);}
    if(!frames)return noErr;
    if(frames>maxFrames||totalChannels<e->offset+e->sources*2){e->failures.fetch_add(1);return noErr;}
    std::memset(e->mixed,0,sizeof(e->mixed));std::memset(e->monitor,0,sizeof(e->monitor));
    for(unsigned s=0;s<e->sources;++s){
        const float *channels[2]{};unsigned strides[2]{};
        for(unsigned c=0;c<2;++c){unsigned wanted=e->offset+s*2+c,base=0;for(unsigned b=0;b<input->mNumberBuffers;++b){auto &v=input->mBuffers[b];if(wanted>=base&&wanted<base+v.mNumberChannels&&v.mData){channels[c]=static_cast<const float*>(v.mData)+(wanted-base);strides[c]=v.mNumberChannels;break;}base+=v.mNumberChannels;}}
        float target=e->sourceMute[s].load()?0:amplitude(e->sourceDB[s].load());
        for(unsigned f=0;f<frames;++f){e->sourceGain[s]=rampTo(e->sourceGain[s],target,e->ramp);for(unsigned c=0;c<2;++c)if(channels[c]){float x=finite(channels[c][f*strides[c]])*e->sourceGain[s];if(int32_t(s)==e->monitorSource)e->monitor[f]+=x*.5f;else e->mixed[c][f]+=x;}}
    }
    if(e->analysisOnly){for(unsigned f=0;f<frames;++f)e->publish((e->mixed[0][f]+e->mixed[1][f])*.5f);return noErr;}
    e->process(frames);
    unsigned channel=0;
    for(unsigned b=0;b<output->mNumberBuffers;++b){auto &v=output->mBuffers[b];if(!v.mData){channel+=v.mNumberChannels;continue;}auto *dst=static_cast<float*>(v.mData);unsigned n=std::min(frames,v.mNumberChannels?v.mDataByteSize/(4*v.mNumberChannels):0);for(unsigned c=0;c<v.mNumberChannels;++c,++channel)if(channel<2)for(unsigned f=0;f<n;++f)dst[f*v.mNumberChannels+c]=e->mixed[channel][f];}
    double elapsed=(mach_absolute_time()-start)*e->hostTickSeconds;if(elapsed>double(frames)/e->rate*.9)e->failures.fetch_add(1);
    return noErr;
}
}
