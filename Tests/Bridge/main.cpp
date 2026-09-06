#include "PluginBridge.h"
#include <AudioToolbox/AudioToolbox.h>
#include <cmath>
#include <initializer_list>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>
#include <sys/wait.h>
#include <signal.h>
void require(bool test,const char*message){if(!test){std::fprintf(stderr,"FAIL: %s\n",message);std::exit(1);}}
int main(int argc,char **argv){
    if(argc>2&&std::strcmp(argv[1],"--worker")==0){
        auto *b=ff_bridge_open(argv[2]);require(b,"worker shared mapping");
        AudioComponentDescription d{kAudioUnitType_Effect,kAudioUnitSubType_NBandEQ,kAudioUnitManufacturer_Apple,0,0};
        auto component=AudioComponentFindNext(nullptr,&d);AudioUnit unit=nullptr;require(component&&AudioComponentInstanceNew(component,&unit)==noErr,"isolated Apple EQ");
        AudioStreamBasicDescription f{48000,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagIsNonInterleaved|kAudioFormatFlagIsPacked,4,1,4,2,32,0};
        for(auto scope:{kAudioUnitScope_Input,kAudioUnitScope_Output})require(AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,scope,0,&f,sizeof(f))==noErr,"stereo format");
        require(ff_bridge_add_unit(b,unit,0)==noErr,"worker callback");require(AudioUnitInitialize(unit)==noErr,"worker initialize");ff_bridge_worker_start(b);
        while(true)usleep(10000);
    }
    char name[128];std::snprintf(name,sizeof(name),"/FoFoBooster.Test.%d",getpid());auto *b=ff_bridge_create(name);require(b,"parent shared mapping");
    pid_t pid=fork();require(pid>=0,"fork worker");if(pid==0){execl(argv[0],argv[0],"--worker",name,nullptr);_exit(127);}
    float left[128],right[128];
    usleep(800000);unsigned completed=0;
    for(unsigned block=0;block<100;++block){for(unsigned f=0;f<128;++f)left[f]=right[f]=.05f;bool ready=ff_bridge_exchange(b,left,right,128);if(ready&&block>0){++completed;require(std::abs(left[64]-.05f)<.0001,"isolated unity output");}usleep(6000);}
    require(completed>95,"worker meets fixed buffer schedule");
    // SIGSTOP models a plugin that never returns; audio callback must not wait.
    kill(pid,SIGSTOP);usleep(20000);
    for(unsigned block=0;block<12;++block){for(unsigned f=0;f<128;++f)left[f]=right[f]=.05f;ff_bridge_exchange(b,left,right,128);require(std::abs(left[64]-.05f)<.0001,"stalled worker dry fallback");}
    require(ff_bridge_misses(b)>0,"misses visible outside realtime callback");kill(pid,SIGCONT);usleep(100000);
    ff_bridge_test_fault(b,0);
    for(unsigned block=0;block<5;++block){for(unsigned f=0;f<128;++f)left[f]=right[f]=.05f;ff_bridge_exchange(b,left,right,128);usleep(6000);}
    int status=0;require(waitpid(pid,&status,0)==pid,"reap crashed worker");require(WIFEXITED(status)&&WEXITSTATUS(status)==86,"fatal plugin terminated only worker");
    require(ff_bridge_fault_slot(b)==0,"crashing slot identified");ff_bridge_mark_dead(b);
    for(unsigned block=0;block<20;++block){for(unsigned f=0;f<128;++f)left[f]=right[f]=.05f;ff_bridge_exchange(b,left,right,128);require(std::isfinite(left[64])&&std::abs(left[64]-.05f)<.0001,"dead worker dry pass-through");}
    ff_bridge_close(b);require(!ff_bridge_open(name),"shared memory unlinked after worker attachment");
    std::puts("PASS isolated AU render, stalled worker, fatal crash, dry fallback, slot attribution, shared-memory cleanup");
}
