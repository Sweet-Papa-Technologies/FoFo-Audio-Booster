#!/usr/bin/env python3
"""Deterministic Xcode project generation; no third-party project generator required."""
import hashlib, pathlib, json
root = pathlib.Path(__file__).resolve().parent.parent
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(tag, **fields):
    key = ident(tag); objects[key] = fields; return key
def quote(value, indent=0):
    pad = '\t' * indent
    if isinstance(value, dict):
        if not value: return '{}'
        return '{\n' + ''.join(pad + '\t' + quote(k) + ' = ' + quote(v, indent+1) + ';\n' for k,v in value.items()) + pad + '}'
    if isinstance(value, list):
        if not value: return '()'
        return '(\n' + ''.join(pad + '\t' + quote(v, indent+1) + ',\n' for v in value) + pad + ')'
    return json.dumps(str(value))
def file(path, kind): return add('file:'+path, isa='PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='<group>')
def build(ref, suffix=''): return add('build:'+ref+suffix, isa='PBXBuildFile', fileRef=ref)
def phase(tag, isa, refs, **extras): return add(tag, isa=isa, buildActionMask=2147483647, files=refs, runOnlyForDeploymentPostprocessing=0, **extras)
app_sources = [file(str(p.relative_to(root)), 'sourcecode.swift') for p in sorted((root/'Sources/FoFoBooster').rglob('*.swift'))]
app_sources += [file(str(p.relative_to(root)), 'sourcecode.cpp.cpp') for p in sorted((root/'Sources/AudioDSP').glob('*.cpp'))]
shared = file('Shared/WidgetIntent.swift','sourcecode.swift')
widget = file('Widget/FoFoBoosterWidget.swift','sourcecode.swift')
resources = [file('LICENSE','text'),file('Sources/FoFoBooster/Resources/AppIcon.icns','image.icns'),file('Sources/FoFoBooster/Resources/Visualizer.metal','text'),file('Sources/FoFoBooster/Resources/Localizable.xcstrings','text.json.xcstrings')]
app_product = add('appProduct', isa='PBXFileReference', explicitFileType='wrapper.application', path='FoFoBooster.app', sourceTree='BUILT_PRODUCTS_DIR')
widget_product = add('widgetProduct', isa='PBXFileReference', explicitFileType='wrapper.app-extension', path='FoFoBoosterWidget.appex', sourceTree='BUILT_PRODUCTS_DIR')
frameworks=[]
for name in ['AppKit','SwiftUI','CoreAudio','AudioToolbox','CoreAudioKit','AVFoundation','Accelerate','MetalKit','Carbon','ServiceManagement','WidgetKit','AppIntents']:
    ref=add(name,isa='PBXFileReference',lastKnownFileType='wrapper.framework',name=name+'.framework',path='System/Library/Frameworks/'+name+'.framework',sourceTree='SDKROOT');frameworks.append(ref)
sparkle_ref=add('sparkle',isa='XCRemoteSwiftPackageReference',repositoryURL='https://github.com/sparkle-project/Sparkle',requirement={'kind':'exactVersion','version':'2.8.0'})
sparkle_product=add('sparkleProduct',isa='XCSwiftPackageProductDependency',package=sparkle_ref,productName='Sparkle')
sparkle_build=add('sparkleBuild',isa='PBXBuildFile',productRef=sparkle_product)
app_phases=[phase('appSources','PBXSourcesBuildPhase',[build(r) for r in app_sources+[shared]]),phase('appResources','PBXResourcesBuildPhase',[build(r) for r in resources]),phase('appFrameworks','PBXFrameworksBuildPhase',[build(r) for r in frameworks]+[sparkle_build])]
widget_phases=[phase('widgetSources','PBXSourcesBuildPhase',[build(widget),build(shared,'widget')]),phase('widgetResources','PBXResourcesBuildPhase',[]),phase('widgetFrameworks','PBXFrameworksBuildPhase',[])]
embed=add('embedWidgetBuild',isa='PBXBuildFile',fileRef=widget_product,settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
app_phases.append(phase('embedWidget','PBXCopyFilesBuildPhase',[embed],dstPath='',dstSubfolderSpec=13,name='Embed App Extensions'))
base={'MACOSX_DEPLOYMENT_TARGET':'14.4','SDKROOT':'macosx','SWIFT_VERSION':'5.0','CLANG_CXX_LANGUAGE_STANDARD':'c++17','CLANG_ENABLE_MODULES':'YES','ENABLE_HARDENED_RUNTIME':'YES','ARCHS':'$(ARCHS_STANDARD)','CODE_SIGN_STYLE':'Manual','DEVELOPMENT_TEAM':'6Y5SZ2K5XY','CODE_SIGN_IDENTITY':'Developer ID Application','SWIFT_EMIT_LOC_STRINGS':'YES','CURRENT_PROJECT_VERSION':'1','MARKETING_VERSION':'0.1.0','GENERATE_INFOPLIST_FILE':'NO','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks']}
def configs(name, extra):
    configs=[]
    for mode in ['Debug','Release']:
        settings={**base,**extra,'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','GCC_OPTIMIZATION_LEVEL':'0' if mode=='Debug' else '3','ONLY_ACTIVE_ARCH':'YES' if mode=='Debug' else 'NO','DEBUG_INFORMATION_FORMAT':'dwarf' if mode=='Debug' else 'dwarf-with-dsym'}
        configs.append(add(name+mode,isa='XCBuildConfiguration',name=mode,buildSettings=settings))
    return add(name+'Configs',isa='XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
widget_id=ident('widgetTarget');app_id=ident('appTarget');project_id=ident('project')
widget_target=add('widgetTarget',isa='PBXNativeTarget',name='FoFoBoosterWidget',productName='FoFoBoosterWidget',productReference=widget_product,productType='com.apple.product-type.app-extension',buildPhases=widget_phases,buildRules=[],dependencies=[],buildConfigurationList=configs('widget',{'PRODUCT_BUNDLE_IDENTIFIER':'com.sweetpapatechnologies.FoFoBooster.widget','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'Config/Widget-Info.plist','CODE_SIGN_ENTITLEMENTS':'Config/Widget.entitlements','SKIP_INSTALL':'YES','APPLICATION_EXTENSION_API_ONLY':'YES'}))
proxy=add('widgetProxy',isa='PBXContainerItemProxy',containerPortal=project_id,proxyType=1,remoteGlobalIDString=widget_id,remoteInfo='FoFoBoosterWidget')
dependency=add('widgetDependency',isa='PBXTargetDependency',target=widget_id,targetProxy=proxy)
add('appTarget',isa='PBXNativeTarget',name='FoFoBooster',productName='FoFoBooster',productReference=app_product,productType='com.apple.product-type.application',buildPhases=app_phases,buildRules=[],dependencies=[dependency],packageProductDependencies=[sparkle_product],buildConfigurationList=configs('app',{'PRODUCT_BUNDLE_IDENTIFIER':'com.sweetpapatechnologies.FoFoBooster','PRODUCT_NAME':'$(TARGET_NAME)','INFOPLIST_FILE':'Config/Info.plist','CODE_SIGN_ENTITLEMENTS':'Config/App.entitlements','HEADER_SEARCH_PATHS':'$(SRCROOT)/Sources/AudioDSP/include','SWIFT_INCLUDE_PATHS':'$(SRCROOT)/Sources/AudioDSP/include','COMBINE_HIDPI_IMAGES':'YES'}))
products=add('products',isa='PBXGroup',children=[app_product,widget_product],name='Products',sourceTree='<group>')
group=add('group',isa='PBXGroup',children=app_sources+[shared,widget]+resources+frameworks+[products],sourceTree='<group>')
add('project',isa='PBXProject',attributes={'LastUpgradeCheck':'1640','BuildIndependentTargetsInParallel':'YES'},buildConfigurationList=configs('project',{}),compatibilityVersion='Xcode 14.0',developmentRegion='en',knownRegions=['en','Base'],mainGroup=group,productRefGroup=products,projectDirPath='',projectRoot='',targets=[app_id,widget_id],packageReferences=[sparkle_ref])
project=root/'FoFoBooster.xcodeproj';project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+quote({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project_id})+'\n')
scheme=project/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
(scheme/'FoFoBooster.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1640" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="FoFoBooster.app" BlueprintName="FoFoBooster" ReferencedContainer="container:FoFoBooster.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app_id}" BuildableName="FoFoBooster.app" BlueprintName="FoFoBooster" ReferencedContainer="container:FoFoBooster.xcodeproj"/></BuildableProductRunnable></LaunchAction><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print('Generated FoFoBooster.xcodeproj')
