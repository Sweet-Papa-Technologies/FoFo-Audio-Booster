#include <metal_stdlib>
using namespace metal;
struct Vertex { float4 position [[position]]; float2 uv; };
vertex Vertex fullscreenVertex(uint id [[vertex_id]]) {
    float2 p=float2((id<<1)&2,id&2); return {float4(p*2-1,0,1),p};
}
float hash(float n) { return fract(sin(n*127.1)*43758.5453); }
fragment float4 visualizerFragment(Vertex in [[stage_in]], constant float *u [[buffer(0)]], constant float *bins [[buffer(1)]], constant float *wave [[buffer(2)]]) {
    float2 uv=in.uv, p=(uv-.5)*float2(u[0]/max(u[1],1.),1.);
    float t=u[2], mode=u[3], light=u[4]; float3 accent=float3(u[8],u[9],u[10]);
    float3 bg=mix(float3(.022,.027,.035),float3(.93,.94,.96),light);
    bg+=mix(float3(.018,.025,.035),float3(.025),light)*exp(-length(p)*2.);
    float energy=0; for(int i=0;i<8;i++)energy+=bins[i]/8.;
    float glow=0; float3 color=accent;
    if(mode<.5) {
        float x=clamp(uv.x,0.,.999)*63.; int i=int(x); float b=mix(bins[i],bins[min(i+1,63)],fract(x));
        float ridge=.42+b*.32+.012*sin(uv.x*8.+t*.4);
        float d=abs(uv.y-ridge); glow=.008/(d+.009)*.5+exp(-d*30.)*.22;
        glow*=smoothstep(0.,.12,uv.x)*smoothstep(1.,.88,uv.x);
        color=mix(float3(1.,.2,.08),float3(1.,.75,.3),uv.y);
    } else if(mode<1.5) {
        float a=atan2(p.y,p.x), radius=.22+energy*.08+.005*sin(t*.5);
        int i=int(fract(a/6.2831853+.5)*63.); float r=length(p);
        float edge=radius+bins[i]*.11;glow=.004/(abs(r-edge)+.006)+.15*exp(-abs(r-radius)*15.);
        color=mix(accent,float3(.7,.4,1.),.5+.5*sin(a));
    } else if(mode<2.5) {
        int i=clamp(int(uv.x*63.),0,62);float w=mix(wave[i],wave[i+1],fract(uv.x*63.));
        float y=.5+w*.25+sin(uv.x*10.+t*.25)*.01;
        glow=exp(-abs(uv.y-y)*350.)*.65;
        color=mix(accent,float3(.25,1.,.7),.65);
    } else if(mode<3.5) {
        float2 q=uv*float2(32,16), cell=floor(q); int i=clamp(int(cell.x*2),0,63);
        float height=bins[i]*13.+1.+.35*sin(t*.3+cell.x*.2);
        float fill=smoothstep(.5,-.5,cell.y-height);
        float led=smoothstep(.46,.33,length((fract(q)-.5)*float2(.8,1.)));
        glow=led*(.06+fill*.85);color=mix(accent,float3(1.,.55,.15),cell.y/16.);
    }
    float3 result=mix(bg+color*glow,bg-color*glow*.55,light);
    return float4(clamp(result,0.,1.),1.);
}

// Drift uses instanced particle quads: one draw, without looping over particles
// for every pixel of a 4K screen.
struct Particle { float4 position [[position]]; float2 local; float4 color; };
vertex Particle particleVertex(uint vertexIndex [[vertex_id]], uint instance [[instance_id]], constant float *u [[buffer(0)]], constant float *bins [[buffer(1)]]) {
    const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    float n=float(instance), t=u[11], aspect=u[0]/max(u[1],1.);
    float2 center=float2(hash(n+7.)*2.-1.,fract(hash(n+9.)+t*(.008+hash(n+2.)*.015))*2.-1.);
    center.x+=sin(t*.15+n)*.045;
    float size=.012+hash(n+5.)*.028;
    float2 local=corners[vertexIndex];
    float3 accent=float3(u[8],u[9],u[10]);float3 color=mix(accent,float3(.85,.45,1.),u[7]);
    if(u[4]>.5)color*=.55;
    return {float4(center+local*size*float2(1./aspect,1.),0,1),local,float4(color,.25+bins[instance%64]*.7)};
}
fragment float4 particleFragment(Particle in [[stage_in]]) {
    float alpha=exp(-dot(in.local,in.local)*5.)*in.color.a;
    return float4(in.color.rgb,alpha);
}

// Retained phosphor energy, ping-ponged at half resolution. Decay uses elapsed
// time so persistence remains consistent at 30 and 60 fps; no captured audio is stored.
fragment half tideHistory(Vertex in [[stage_in]], constant float *u [[buffer(0)]], constant float *wave [[buffer(2)]], texture2d<half> previous [[texture(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv=in.uv, texel=1./float2(previous.get_width(),previous.get_height());
    float old=0;
    if(u[13]>.5) {
        old=float(previous.sample(linearSampler,uv).r)*.6;
        old+=float(previous.sample(linearSampler,uv+float2(texel.x,0)).r)*.1;
        old+=float(previous.sample(linearSampler,uv-float2(texel.x,0)).r)*.1;
        old+=float(previous.sample(linearSampler,uv+float2(0,texel.y)).r)*.1;
        old+=float(previous.sample(linearSampler,uv-float2(0,texel.y)).r)*.1;
    }
    float x=clamp(uv.x,0.,.999)*63.;int i=min(int(x),62);
    float y=.5+mix(wave[i],wave[i+1],fract(x))*.25+sin(uv.x*10.+u[2]*.25)*.01;
    float trace=exp(-abs(uv.y-y)*350.)*.8;
    return half(max(trace,old*exp(-u[12]*3.5)));
}
fragment float4 tideDisplay(Vertex in [[stage_in]], constant float *u [[buffer(0)]], texture2d<half> history [[texture(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float energy=float(history.sample(linearSampler,in.uv).r), light=u[4];
    float3 color=mix(float3(u[8],u[9],u[10]),float3(.25,1.,.7),.65);
    float3 bg=mix(float3(.022,.027,.035),float3(.93,.94,.96),light);
    return float4(clamp(mix(bg+color*energy,bg-color*energy*.55,light),0.,1.),1.);
}
