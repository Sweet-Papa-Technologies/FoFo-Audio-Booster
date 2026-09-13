#include <metal_stdlib>
using namespace metal;
// Uniforms shared by Renderer and the offscreen validator:
// size.xy, time, preset, light, quality, flux, centroid, accent.rgb,
// motionClock, delta, historyValid, level, bass, mids, treble, onset.
struct Vertex { float4 position [[position]]; float2 uv; };
vertex Vertex fullscreenVertex(uint id [[vertex_id]]) {
    float2 p=float2((id<<1)&2,id&2); return {float4(p*2-1,0,1),p};
}
float hash(float n) { return fract(sin(n*127.1)*43758.5453); }
float spectrum(constant float *bins, float x) {
    float q=clamp(x,0.,1.)*63.; int i=min(int(q),62);
    return mix(bins[i],bins[i+1],q-float(i));
}
float waveform(constant float *wave, float x) {
    float q=clamp(x,0.,1.)*255.;int i=min(int(q),254);
    return mix(wave[i],wave[i+1],q-float(i));
}
float line(float d, float width) { return exp(-abs(d)/max(width,.0001)); }
float3 palette(float x, float3 accent) {
    return mix(accent,float3(.24,.72,1.),.45+.4*sin(x*3.14159));
}
float3 shade(float2 uv, constant float *u, constant float *bins, constant float *wave, constant float *peaks) {
    float aspect=u[0]/max(u[1],1.), t=u[11], mode=u[3], light=u[4];
    float level=u[14], bass=u[15], mids=u[16], treble=u[17], beat=u[18];
    float2 p=(uv-.5)*float2(aspect,1.);
    float3 accent=float3(u[8],u[9],u[10]);
    float3 ink=float3(.012,.019,.034), radiance=0.;
    float vignette=exp(-dot(p,p)*1.3);
    float slow=sin(p.x*2.6+p.y*3.+t*.11), curl=sin(p.y*6.-p.x*1.8+t*.17+slow);
    float atmosphere=exp(-abs(p.y-.15*sin(p.x*2.+t*.09)-curl*.09)*7.);
    radiance+=palette(u[7]+slow*.2,accent)*atmosphere*(.045+.065*level)*vignette;
    float edgeFade=smoothstep(0.,.07,uv.x)*(1.-smoothstep(.93,1.,uv.x));
    if(mode<.5) {
        ink=float3(.025,.009,.018);
        // Layered spectrum ridges, luminous valleys, and a slower distant horizon.
        for(int layer=0;layer<3;layer++) {
            float n=float(layer), b=spectrum(bins,uv.x);
            float ridge=.36+n*.095+b*(.22-n*.043)+.025*sin(uv.x*10.+t*(.18+n*.05)+n*2.);
            float d=uv.y-ridge, below=1.-smoothstep(-.005,.025,d);
            float3 hot=mix(float3(.9,.11,.045),float3(1.,.69,.24),n*.3+b*.2);
            float body=below*exp(min(d,0.)*(7.+n*3.))*(.12+.12*level);
            float crest=line(d,.003+n*.001)*(.3+b*.6)+line(d,.025)*.12;
            radiance+=hot*(body+crest)*edgeFade*(1.-n*.17);
        }
        radiance+=float3(.7,.08,.02)*exp(-length(p-float2(0.,-.15))*3.)*(.06+bass*.16);
    } else if(mode<1.5) {
        float angle=atan2(p.y,p.x), r=length(p), angleBin=abs(angle)/3.14159265;
        float radius=.20+bass*.055, b=spectrum(bins,angleBin);
        float ring=radius+b*.075+.006*sin(angle*6.-t*.3)*(1.+mids);
        float3 color=palette(angleBin+u[7]*.4,accent);
        radiance+=color*(line(r-ring,.0035)*.75+line(r-ring,.027)*.19);
        float orbit=radius+.12+.015*sin(angle*3.+t*.16)+spectrum(bins,1.-angleBin)*.028;
        radiance+=palette(1.-angleBin,accent)*(line(r-orbit,.0015)*(.16+treble*.24)+line(r-orbit,.018)*.055);
        float inner=radius*.70+.012*sin(angle*4.+t*.22);
        radiance+=color*line(r-inner,.002)*(.12+mids*.16);
        float core=exp(-r*r/((.1+bass*.025)*(.1+bass*.025)));
        radiance+=palette(u[7],accent)*core*(.18+level*.28);
        float rays=pow(max(0.,cos(angle*32.+t*.04)),12.)*exp(-abs(r-radius-.04)*12.);
        radiance+=color*rays*(.025+treble*.09);
        // Soft beat bloom changes size and density rather than flashing the frame.
        radiance+=color*line(r-radius-.07-beat*.06,.045)*beat*.07;
    } else if(mode<2.5) {
        ink=float3(.006,.024,.034);
        float w=waveform(wave,uv.x), swell=sin(uv.x*9.+t*.23)*(.025+bass*.025);
        float y=.53+w*(.16+level*.08)+swell;
        float3 water=palette(.35+u[7]*.6,accent);
        // Broad flowing ribbons behind the true time-domain trace.
        for(int layer=0;layer<3;layer++) {
            float n=float(layer), bend=.47+n*.065+sin(uv.x*(5.+n*2.)+t*(.16+n*.035)+n)*(.045+bass*.045);
            bend+=waveform(wave,clamp(uv.x*.9+n*.045,0.,1.))*(.06+n*.015);
            radiance+=palette(n*.25,accent)*line(uv.y-bend,.018+n*.005)*(.11+level*.13)*edgeFade;
        }
        radiance+=water*(line(uv.y-y,.0022)*.55+line(uv.y-y,.014)*.15)*edgeFade;
        float reflected=.37-w*.12-swell*.6;
        radiance+=water*line(uv.y-reflected,.007)*(.07+level*.08)*edgeFade;
        float depth=exp(-abs(uv.y-.43)*6.);
        radiance+=water*depth*(.015+bass*.035)*edgeFade;
    } else if(mode<3.5) {
        ink=float3(.008,.021,.021);
        float2 q=float2(uv.x*32.,(uv.y-.27)*24.), cell=floor(q);
        float b=spectrum(bins,(cell.x+.5)/32.), h=b*13.+.5;
        float2 local=abs(fract(q)-.5);
        float led=(1.-smoothstep(.31,.43,local.x))*(1.-smoothstep(.29,.42,local.y));
        float fill=1.-smoothstep(h-.4,h+.35,cell.y);
        float peak=spectrum(peaks,(cell.x+.5)/32.)*13.;
        float peakDot=1.-smoothstep(.2,.6,abs(cell.y-floor(peak)));
        float bounds=step(0.,q.y)*(1.-step(16.,q.y))*edgeFade;
        float3 color=mix(float3(.15,.86,.67),mix(accent,float3(1.,.3,.1),.35),clamp(cell.y/14.,0.,1.));
        radiance+=color*led*(.027+fill*(.32+level*.22)+peakDot*.22)*bounds;
        // Perspective floor, reflections, and a glowing horizon give the matrix space.
        float floorY=max(.02,.28-uv.y), floorMask=1.-smoothstep(.22,.29,uv.y);
        float gx=abs(fract(p.x/floorY*1.5+.5)-.5);
        float gy=abs(fract(.25/floorY-t*.12)-.5);
        float grid=(line(gx,.026)+line(gy,.018))*floorMask*exp(-floorY*7.);
        radiance+=palette(.25,accent)*grid*(.065+bass*.065);
        radiance+=color*exp(-abs(uv.y-.275)*27.)*(.02+b*.13)*edgeFade;
    } else {
        ink=float3(.015,.012,.031);
        // A wide nebula with several currents; particles occupy different depths.
        for(int layer=0;layer<3;layer++) {
            float n=float(layer), flow=sin(p.x*(2.+n*.8)+t*(.12+n*.025)+n*2.);
            flow+=.35*sin(p.x*5.-t*.1+n);
            float d=p.y-flow*(.10+bass*.045)-.06*cos(t*.1+n*3.);
            float nebula=line(d,.08+n*.04)*vignette;
            radiance+=palette(n*.4+u[7],accent)*nebula*(.05+level*.065);
            radiance+=palette(n*.4,accent)*line(d,.003)*(.025+mids*.04)*vignette;
        }
    }
    float3 bg=mix(ink,float3(.93,.95,.965),light);
    float3 result=light>.5 ? bg-radiance*.58 : bg+radiance;
    return clamp(result,0.,1.);
}
fragment float4 visualizerFragment(Vertex in [[stage_in]], constant float *u [[buffer(0)]], constant float *bins [[buffer(1)]], constant float *wave [[buffer(2)]], constant float *peaks [[buffer(3)]]) {
    return float4(shade(in.uv,u,bins,wave,peaks),1.);
}

// Instanced foreground: no per-pixel particle loops, including at 4K.
struct Particle { float4 position [[position]]; float2 local; float4 color; };
vertex Particle particleVertex(uint vertexIndex [[vertex_id]], uint instance [[instance_id]], constant float *u [[buffer(0)]], constant float *bins [[buffer(1)]]) {
    const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    float n=float(instance), t=u[11], aspect=u[0]/max(u[1],1.), depth=hash(n+4.);
    float speed=.016+depth*.035, mode=u[3];
    float2 center=float2(hash(n+7.)*2.-1.,fract(hash(n+9.)+t*speed)*2.-1.);
    center.x+=sin(t*.13+n)*(.025+u[15]*.025);
    if(mode>3.5) {
        center.x=fract(hash(n+7.)+t*(.012+depth*.017))*2.-1.;
        center.y=sin(center.x*3.+n+t*.16)*(.13+u[15]*.05)+(hash(n+9.)-.5)*1.6;
    }
    float size=.002+depth*depth*.015, b=bins[instance%64];
    size*=1.+b*.7+u[18]*.2;
    float2 local=corners[vertexIndex], stretch=mode>3.5 ? float2(1.5+u[6],1.) : float2(1.,1.8);
    float3 accent=float3(u[8],u[9],u[10]);
    float3 color=mode<.5 ? mix(float3(1.,.24,.06),float3(1.,.78,.35),depth) : palette(depth+u[7],accent);
    if(u[4]>.5)color*=.45;
    float alpha=(.10+depth*.30+b*.22)*(mode>3.5 ? 1.:.45);
    return {float4(center+local*size*stretch*float2(1./aspect,1.),0,1),local,float4(color,alpha)};
}
fragment float4 particleFragment(Particle in [[stage_in]]) {
    float alpha=exp(-dot(in.local,in.local)*4.)*in.color.a;
    return float4(in.color.rgb,alpha);
}

fragment half tideHistory(Vertex in [[stage_in]], constant float *u [[buffer(0)]], constant float *wave [[buffer(2)]], texture2d<half> previous [[texture(0)]]) {
    constexpr sampler sampleLinear(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv=in.uv, texel=1./float2(previous.get_width(),previous.get_height());
    float2 sampleUV=float2(uv.x,1.-uv.y)+float2(sin(uv.y*7.+u[11]*.12)*u[12]*.004,u[12]*.018);
    float old=0.;
    if(u[13]>.5) {
        old=float(previous.sample(sampleLinear,sampleUV).r)*.6;
        old+=float(previous.sample(sampleLinear,sampleUV+float2(texel.x,0)).r)*.1;
        old+=float(previous.sample(sampleLinear,sampleUV-float2(texel.x,0)).r)*.1;
        old+=float(previous.sample(sampleLinear,sampleUV+float2(0,texel.y)).r)*.1;
        old+=float(previous.sample(sampleLinear,sampleUV-float2(0,texel.y)).r)*.1;
    }
    float y=.53+waveform(wave,uv.x)*(.16+u[14]*.08)+sin(uv.x*9.+u[11]*.23)*(.025+u[15]*.025);
    float trace=line(uv.y-y,.0025)*(.22+u[14]*.28)*smoothstep(0.,.07,uv.x)*(1.-smoothstep(.93,1.,uv.x));
    return half(max(trace,old*exp(-u[12]*2.1)));
}
fragment float4 tideDisplay(Vertex in [[stage_in]], constant float *u [[buffer(0)]], constant float *bins [[buffer(1)]], constant float *wave [[buffer(2)]], constant float *peaks [[buffer(3)]], texture2d<half> history [[texture(0)]]) {
    constexpr sampler sampleLinear(coord::normalized,address::clamp_to_edge,filter::linear);
    float energy=float(history.sample(sampleLinear,float2(in.uv.x,1.-in.uv.y)).r);
    float3 color=palette(.5,float3(u[8],u[9],u[10]));
    float3 scene=shade(in.uv,u,bins,wave,peaks);
    return float4(clamp(scene+color*energy*(u[4]>.5 ? -.45:.55),0.,1.),1.);
}
