#include "PluginBridge.h"
#include <atomic>
#include <algorithm>
#include <cstring>
#include <new>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cmath>
namespace {
constexpr uint32_t framesMax=4096, packets=8, magic=0x46464232;
enum State:uint32_t { empty,requested,rendering,ready,writing };
struct Packet {
    std::atomic<uint32_t> state{empty};
    uint32_t frames=0;
    uint64_t sequence=0;
    float input[2][framesMax]{},output[2][framesMax]{};
};
struct Shared {
    uint32_t version=magic;
    std::atomic<bool> alive{false},stop{false};
    std::atomic<int32_t> renderingSlot{-1},editingSlot{-1},testFault{-1};
    std::atomic<uint32_t> failedSlots{0},misses{0};
    Packet packet[packets];
};
struct Unit {AudioUnit unit=nullptr;const float *left=nullptr,*right=nullptr;uint32_t frames=0;};
OSStatus pull(void *context,AudioUnitRenderActionFlags*,const AudioTimeStamp*,UInt32,UInt32 frames,AudioBufferList *list){
    auto &u=*static_cast<Unit*>(context);
    if(frames>u.frames||list->mNumberBuffers!=2)return kAudioUnitErr_TooManyFramesToProcess;
    for(unsigned c=0;c<2;++c){auto &b=list->mBuffers[c];auto *source=c?u.right:u.left;b.mNumberChannels=1;b.mDataByteSize=frames*4;if(b.mData)std::memcpy(b.mData,source,frames*4);else b.mData=const_cast<float*>(source);}
    return noErr;
}
}
struct FFBridge {
    Shared *shared=nullptr;int fd=-1;pthread_t thread{};bool started=false,owner=false;char name[128]{};
    uint64_t sequence=0;uint32_t lastFrames=0;
    float dry[2][framesMax]{},mixed[2][framesMax]{},scratch[2][framesMax]{};
    Unit units[8];double sampleTime=0;
};
static FFBridge *mapFile(const char *path,bool create){
    if(std::strlen(path)>=128)return nullptr;
    int fd=shm_open(path,O_RDWR|(create?(O_CREAT|O_EXCL):0),0600);if(fd<0)return nullptr;
    struct stat st{};
    if((create&&ftruncate(fd,sizeof(Shared))!=0)||fstat(fd,&st)!=0||st.st_uid!=getuid()||(st.st_size<off_t(sizeof(Shared))||st.st_size>=off_t(sizeof(Shared)+getpagesize()))){close(fd);if(create)shm_unlink(path);return nullptr;}
    auto *m=static_cast<Shared*>(mmap(nullptr,sizeof(Shared),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0));
    if(m==MAP_FAILED){close(fd);if(create)shm_unlink(path);return nullptr;}
    if(create)new(m) Shared();
    if(m->version!=magic){munmap(m,sizeof(Shared));close(fd);return nullptr;}
    auto *b=new(std::nothrow) FFBridge();if(!b){munmap(m,sizeof(Shared));close(fd);if(create)shm_unlink(path);return nullptr;}
    b->shared=m;b->fd=fd;b->owner=create;std::strncpy(b->name,path,127);if(!create)shm_unlink(path);return b;
}
static void *worker(void *context){
    auto &b=*static_cast<FFBridge*>(context);auto &s=*b.shared;
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
    s.alive.store(true,std::memory_order_release);
    while(!s.stop.load(std::memory_order_acquire)){
        Packet *next=nullptr;uint64_t oldest=UINT64_MAX;
        for(auto &p:s.packet)if(p.state.load(std::memory_order_acquire)==requested&&p.sequence<oldest){next=&p;oldest=p.sequence;}
        if(!next){usleep(100);continue;}
        uint32_t expected=requested;if(!next->state.compare_exchange_strong(expected,rendering,std::memory_order_acq_rel))continue;
        unsigned frames=std::min(next->frames,framesMax);
        for(unsigned c=0;c<2;++c)std::memcpy(b.mixed[c],next->input[c],frames*4);
        for(unsigned index=0;index<8;++index){auto &u=b.units[index];if(!u.unit||(s.failedSlots.load()&(1u<<index)))continue;
            s.renderingSlot.store(int32_t(index),std::memory_order_release);
            if(s.testFault.load()==int32_t(index))_exit(86);
            u.left=b.mixed[0];u.right=b.mixed[1];u.frames=frames;
            struct StereoList{UInt32 count;AudioBuffer buffers[2];} list{2,{{1,frames*4,b.scratch[0]},{1,frames*4,b.scratch[1]}}};
            AudioTimeStamp stamp{};stamp.mSampleTime=b.sampleTime;stamp.mFlags=kAudioTimeStampSampleTimeValid;AudioUnitRenderActionFlags flags=0;
            OSStatus result=AudioUnitRender(u.unit,&flags,&stamp,0,frames,reinterpret_cast<AudioBufferList*>(&list));
            if(result||list.count!=2||!list.buffers[0].mData||!list.buffers[1].mData||list.buffers[0].mDataByteSize<frames*4||list.buffers[1].mDataByteSize<frames*4){s.failedSlots.fetch_or(1u<<index);continue;}
            for(unsigned c=0;c<2;++c){auto *source=static_cast<float*>(list.buffers[c].mData);for(unsigned f=0;f<frames;++f)b.mixed[c][f]=std::isfinite(source[f])?source[f]:0.f;}
        }
        s.renderingSlot.store(-1,std::memory_order_release);b.sampleTime+=frames;
        for(unsigned c=0;c<2;++c)std::memcpy(next->output[c],b.mixed[c],frames*4);
        next->state.store(ready,std::memory_order_release);
    }
    s.alive.store(false,std::memory_order_release);return nullptr;
}
extern "C" {
FFBridge *ff_bridge_create(const char *p){return mapFile(p,true);}
FFBridge *ff_bridge_open(const char *p){return mapFile(p,false);}
void ff_bridge_mark_dead(FFBridge *b){if(b)b->shared->alive.store(false,std::memory_order_release);}
int32_t ff_bridge_fault_slot(FFBridge *b){if(!b)return -1;int32_t slot=b->shared->renderingSlot.load();if(slot>=0)return slot;auto bits=b->shared->failedSlots.load();for(unsigned i=0;i<8;++i)if(bits&(1u<<i))return int32_t(i);return b->shared->editingSlot.load();}
uint32_t ff_bridge_failed_slots(FFBridge *b){return b?b->shared->failedSlots.load():0;}
uint32_t ff_bridge_misses(FFBridge *b){return b?b->shared->misses.load():0;}
void ff_bridge_set_editing(FFBridge *b,int32_t slot){if(b)b->shared->editingSlot.store(slot);}
void ff_bridge_test_fault(FFBridge *b,int32_t slot){if(b)b->shared->testFault.store(slot);}
bool ff_bridge_exchange(FFBridge *b,float *left,float *right,uint32_t frames){
    if(frames>framesMax)return false;
    auto &s=*b->shared;const uint64_t sequence=b->sequence++;
    auto &out=s.packet[sequence%packets];uint32_t state=out.state.load(std::memory_order_acquire);
    if((state==empty||state==ready)&&out.state.compare_exchange_strong(state,writing,std::memory_order_acq_rel)){
        out.frames=frames;out.sequence=sequence;std::memcpy(out.input[0],left,frames*4);std::memcpy(out.input[1],right,frames*4);out.state.store(requested,std::memory_order_release);
    }
    Packet *previous=sequence?&s.packet[(sequence-1)%packets]:nullptr;
    bool available=s.alive.load(std::memory_order_acquire)&&previous&&previous->state.load(std::memory_order_acquire)==ready&&previous->sequence==sequence-1&&previous->frames==frames;
    if(sequence&&!available)s.misses.fetch_add(1,std::memory_order_relaxed);
    for(unsigned c=0;c<2;++c){float *audio=c?right:left;for(unsigned f=0;f<frames;++f){float input=audio[f];audio[f]=available?previous->output[c][f]:(b->lastFrames==frames?b->dry[c][f]:0.f);b->dry[c][f]=input;}}
    b->lastFrames=frames;if(available)previous->state.store(empty,std::memory_order_release);
    return available||sequence==0;
}
OSStatus ff_bridge_add_unit(FFBridge *b,AudioUnit unit,uint32_t slot){if(slot>=8||b->started)return kAudio_ParamError;auto &u=b->units[slot];u.unit=unit;AURenderCallbackStruct callback{pull,&u};return AudioUnitSetProperty(unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,sizeof(callback));}
void ff_bridge_worker_start(FFBridge *b){if(!b->started){b->shared->stop.store(false);b->started=pthread_create(&b->thread,nullptr,worker,b)==0;}}
void ff_bridge_worker_stop(FFBridge *b){if(b&&b->started){b->shared->stop.store(true);pthread_join(b->thread,nullptr);b->started=false;}}
void ff_bridge_close(FFBridge *b){if(!b)return;ff_bridge_worker_stop(b);munmap(b->shared,sizeof(Shared));close(b->fd);if(b->owner)shm_unlink(b->name);delete b;}
}
