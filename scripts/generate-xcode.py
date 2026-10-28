#!/usr/bin/env python3
"""Generate a dependency-free Xcode application project; SwiftPM runs the same core tests."""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
project=root/'MacMirror.xcodeproj';project.mkdir(exist_ok=True)
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def q(s): return json.dumps(str(s))
objects=[]
def obj(key,value): objects.append(f'{uid(key)} = {{ {value} }};');return uid(key)
files=sorted((root/'macos/Core').glob('*.swift'))+sorted((root/'macos/App').glob('*.swift'))
refs=[];build=[]
for file in files:
 p=file.relative_to(root).as_posix()
 refs.append(obj(p,f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {q(p)}; sourceTree = "<group>";'))
 build.append(obj('build'+p,f'isa = PBXBuildFile; fileRef = {uid(p)};'))
resources=obj('web','isa = PBXFileReference; lastKnownFileType = folder; path = receiver/web; sourceTree = "<group>";')
resourcebuild=obj('webbuild',f'isa = PBXBuildFile; fileRef = {resources};')
icon=obj('icon','isa = PBXFileReference; lastKnownFileType = image.icns; path = macos/Resources/MacMirror.icns; sourceTree = "<group>";')
iconbuild=obj('iconbuild',f'isa = PBXBuildFile; fileRef = {icon};')
product=obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; path = MacMirror.app; sourceTree = BUILT_PRODUCTS_DIR;')
products=obj('products',f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
group=obj('group',f'isa = PBXGroup; children = ({",".join(refs+[resources,icon,products])},); sourceTree = "<group>";')
sources=obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(build)},); runOnlyForDeploymentPostprocessing = 0;')
resphase=obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({resourcebuild},{iconbuild},); runOnlyForDeploymentPostprocessing = 0;')
frameworks=obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
projcfg=[];targetcfg=[]
for mode in ['Debug','Release']:
 projcfg.append(obj('proj'+mode,f'isa = XCBuildConfiguration; name = {mode}; buildSettings = {{ SDKROOT = macosx; MACOSX_DEPLOYMENT_TARGET = 14.0; CLANG_ENABLE_MODULES = YES; }};'))
 targetcfg.append(obj('target'+mode,f'''isa = XCBuildConfiguration; name = {mode}; buildSettings = {{
 PRODUCT_NAME = MacMirror; PRODUCT_BUNDLE_IDENTIFIER = local.macmirror.app;
 INFOPLIST_FILE = macos/Resources/Info.plist; GENERATE_INFOPLIST_FILE = NO;
 SWIFT_VERSION = 5.0; SWIFT_STRICT_CONCURRENCY = minimal;
 SWIFT_OPTIMIZATION_LEVEL = "{'-Onone' if mode=='Debug' else '-O'}";
 CODE_SIGN_STYLE = Manual; CODE_SIGN_IDENTITY = "-"; ENABLE_APP_SANDBOX = NO;
 LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/../Frameworks";
 CURRENT_PROJECT_VERSION = 1; MARKETING_VERSION = 1.0; COMBINE_HIDPI_IMAGES = YES;
 }};'''))
pc=obj('projectconfigs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(projcfg)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
tc=obj('targetconfigs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(targetcfg)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=obj('target',f'isa = PBXNativeTarget; buildConfigurationList = {tc}; buildPhases = ({sources},{frameworks},{resphase},); buildRules = (); dependencies = (); name = MacMirror; productName = MacMirror; productReference = {product}; productType = "com.apple.product-type.application";')
proj=obj('project',f'isa = PBXProject; attributes = {{ LastSwiftUpdateCheck = 2620; LastUpgradeCheck = 2620; }}; buildConfigurationList = {pc}; compatibilityVersion = "Xcode 14.0"; developmentRegion = pt; hasScannedForEncodings = 0; knownRegions = (pt,en,Base); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {proj}; }}\n')
schemes=project/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
(schemes/'MacMirror.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2620" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="MacMirror.app" BlueprintName="MacMirror" ReferencedContainer="container:MacMirror.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="MacMirror.app" BlueprintName="MacMirror" ReferencedContainer="container:MacMirror.xcodeproj"/></BuildableProductRunnable></LaunchAction></Scheme>''')
print(project)
