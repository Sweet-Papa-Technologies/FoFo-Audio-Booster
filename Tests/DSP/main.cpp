#include "AudioDSP.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>
#include <limits>
#include <algorithm>
#include <cstring>
void require(bool ok,const char *message){if(!ok){std::fprintf(stderr,"FAIL: %s\n",message);std::exit(1);}}
int main(){
    constexpr unsigned block=128;float l[block],r[block],ol[block],orr[block];
    for(double rate:{44100.,48000.,96000.,192000.}) {
        auto *e=ff_create(rate,1,0,false);require(e,"allocation");ff_set_master(e,24,-1,0,false,false,-14,24);
        float maximum=0;std::vector<float> rendered;
        for(unsigned b=0;b<800;++b){for(unsigned f=0;f<block;++f){double t=(b*block+f)/rate;l[f]=float(.85*std::sin(2*M_PI*997*t)+.14*std::sin(2*M_PI*17311*t));r[f]=float(.9*std::sin(2*M_PI*11003*t));}
            ff_process(e,l,r,ol,orr,block);for(unsigned f=0;f<block;++f){require(std::isfinite(ol[f])&&std::isfinite(orr[f]),"finite output");maximum=std::max({maximum,std::abs(ol[f]),std::abs(orr[f])});rendered.push_back(ol[f]);}}
        require(maximum<=std::pow(10.,-1./20)+1e-6,"sample ceiling at +24 dB");
        // Independent 16x, 64-tap windowed-sinc reconstruction (not the limiter's detector).
        double truePeak=0;
        for(unsigned i=32;i+32<rendered.size();++i)for(unsigned phase=0;phase<16;++phase){double sum=0,norm=0;for(int k=-31;k<=32;++k){double x=k-double(phase)/16;double w=std::abs(x)<1e-12?1:std::sin(M_PI*x)/(M_PI*x);w*=.5+.5*std::cos(M_PI*x/33);sum+=rendered[i+k]*w;norm+=w;}truePeak=std::max(truePeak,std::abs(sum/norm));}
        require(truePeak<=std::pow(10.,-1./20)+.002,"independent reconstructed true-peak ceiling");
        require(ff_meters(e).reductionDB>10,"gain-reduction meter");ff_destroy(e);
        std::printf("PASS limiter at %.0f Hz, sample %.4f, reconstructed %.4f\n",rate,maximum,truePeak);
    }
    auto *e=ff_create(48000,1,0,false);ff_set_analysis(e,true);
    for(unsigned b=0;b<4000;++b){for(unsigned f=0;f<block;++f)l[f]=r[f]=float(.1*std::sin(2*M_PI*1000*(b*block+f)/48000));ff_process(e,l,r,ol,orr,block);}
    auto meters=ff_meters(e);require(meters.loudnessLUFS>-24&&meters.loudnessLUFS<-19,"K-weighted stereo sine loudness");
    float ring[4096];require(ff_read_samples(e,ring,4096)==4096,"bounded SPSC delivery");
    float integrated=ff_meters(e).integratedLUFS;
    require(integrated>-24&&integrated<-19,"integrated K-weighted sine reference");
    // Silence must not lower integrated loudness through the absolute gate.
    for(unsigned b=0;b<2000;++b){for(unsigned f=0;f<block;++f)l[f]=r[f]=0;ff_process(e,l,r,ol,orr,block);}
    require(std::abs(ff_meters(e).integratedLUFS-integrated)<.15,"integrated absolute gate excludes silence");
    // A signal 30 dB below the reference clears the absolute gate but must be
    // rejected by the relative gate; only boundary blocks change the result.
    for(unsigned b=0;b<2000;++b){for(unsigned f=0;f<block;++f)l[f]=r[f]=float(.0031623*std::sin(2*M_PI*1000*(b*block+f)/48000));ff_process(e,l,r,ol,orr,block);}
    require(std::abs(ff_meters(e).integratedLUFS-integrated)<.15,"integrated relative gate excludes quiet sections");
    ff_set_master(e,0,-1,1,false,false,-14,12);
    for(unsigned b=0;b<150;++b)ff_process(e,l,r,ol,orr,block);
    require(std::abs(ol[64])<.0001,"right balance silences left after ramp");
    ff_set_master(e,0,-1,0,true,false,-14,12);
    for(unsigned b=0;b<150;++b){for(unsigned f=0;f<block;++f)r[f]=-l[f];ff_process(e,l,r,ol,orr,block);}
    require(std::abs(ol[64])<.0001&&std::abs(orr[64])<.0001,"mono downmix cancels opposite-phase input");
    l[0]=std::numeric_limits<float>::quiet_NaN();r[1]=std::numeric_limits<float>::infinity();ff_process(e,l,r,ol,orr,block);
    for(float x:ol)require(std::isfinite(x),"non-finite plugin/sample containment");
    ff_set_fade(e,false);for(unsigned b=0;b<150;++b)ff_process(e,l,r,ol,orr,block);
    require(std::abs(ol[64])<.0001,"fade-out completes");ff_destroy(e);
    // Null test: an active unity-gain path is exact after fade and lookahead,
    // for samples below the ceiling. RoutingTests separately prove full-scale
    // zero-gain audio creates no tap, so it never enters the limiter.
    e=ff_create(48000,1,0,false);
    std::vector<float> original,processed;
    for(unsigned b=0;b<300;++b){for(unsigned f=0;f<block;++f){l[f]=r[f]=float(.2*std::sin((b*block+f)*.12345));original.push_back(l[f]);}ff_process(e,l,r,ol,orr,block);processed.insert(processed.end(),ol,ol+block);}
    for(unsigned i=20000;i<processed.size();++i)require(processed[i]==original[i-72],"delay-compensated unity null test");ff_destroy(e);
    // Exercise the actual IOProc's buffer mapping, series gain, and monitor exclusion.
    e=ff_create(48000,2,0,false);ff_set_source(e,0,6,false);ff_set_master(e,3,-1,0,false,false,-14,12);ff_set_monitor_source(e,1);ff_set_analysis(e,true);
    float a[block*2],monitor[block*2],out[block*2];std::fill(a,a+block*2,.01f);std::fill(monitor,monitor+block*2,.2f);
    struct TwoBuffers { UInt32 count; AudioBuffer buffers[2]; } input{2,{{2,sizeof(a),a},{2,sizeof(monitor),monitor}}};
    AudioBufferList output{1,{{2,sizeof(out),out}}};AudioTimeStamp time{};
    for(unsigned b=0;b<400;++b)ff_io_proc(0,&time,reinterpret_cast<AudioBufferList*>(&input),&time,&output,&time,e);
    require(std::abs(out[100]-.01*std::pow(10.,9./20))<.0001,"per-source gain precedes master and monitor is inaudible");
    ff_destroy(e);
    // A real AU render error is contained and marks only its slot for bypass.
    AudioComponentDescription description{kAudioUnitType_Effect,kAudioUnitSubType_NBandEQ,kAudioUnitManufacturer_Apple,0,0};
    AudioComponent component=AudioComponentFindNext(nullptr,&description);require(component,"Apple EQ is available");
    AudioUnit unit=nullptr;require(AudioComponentInstanceNew(component,&unit)==noErr,"instantiate Apple EQ");
    e=ff_create(48000,1,0,false);require(ff_attach_plugin(e,unit,0,false,0)==noErr,"connect AU callback");
    ff_process(e,l,r,ol,orr,block);require(ff_meters(e).pluginFailures==1,"uninitialized AU auto-bypassed after render failure");
    ff_destroy(e);AudioComponentInstanceDispose(unit);
    std::puts("PASS unity null test, real callback mixing, monitor exclusion, AU render-failure containment");
    require(!ff_create(0,1,0,false),"reject invalid rate");require(!ff_create(48000,65,0,false),"reject source overflow");
    std::puts("PASS loudness, ring buffer, balance, mono, non-finite safety, fade, bounds");
}
