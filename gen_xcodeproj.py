# -*- coding: utf-8 -*-
"""
生成 TradeMirror.xcodeproj —— **生成器驱动,不要手改 .pbxproj**。
(与 applab/build_worklog.py 同一约定:手改生成物 = 下次重跑就丢。)

加文件后重跑本脚本即可。ID 由路径 hash 决定 → 幂等,重跑不会打乱 diff。
"""
import hashlib, os, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
APP_NAME   = "TradeMirror"
BUNDLE_ID  = "dev.ruizhang.trademirror"
DEPLOY_TGT = "17.0"
# ★ 版本号只有**一个**来源:仓库根的 VERSION 文件。
# 写死在这里的后果我已经吃过一次:v0.7→v1.4 八个版本过去了,
# App 里显示的还是 v0.6 —— 用户根本没法确认自己装的是哪一版,
# 而「做完了但验不了 = 没做完」。
APP_VERSION = (Path(__file__).resolve().parent / "VERSION").read_text().strip()
# ★ 构建号 = 生成时刻(MMDDHHMM)。2026-09-01 用户重装后「没看到更新」——
#   因为版本号一直写死 0.1,**根本没法判断装没装上**。这条是我的基础错误。
from datetime import datetime as _dt
BUILD_NUMBER = _dt.now().strftime("%m%d%H%M")
PROJ = ROOT / f"{APP_NAME}.xcodeproj"

# ★ 开发团队 ID:装真机必须有,但它跟个人 Apple 账号绑定,**不入库**。
#   来源优先级:环境变量 DEVELOPMENT_TEAM > 本地 .developer_team 文件 > 空(只能跑模拟器)。
#   Xcode 在 Signing & Capabilities 里选过 Team 之后会把它写进 pbxproj,
#   本脚本重跑时会覆盖 pbxproj —— 所以必须从这里读回来,否则每次重新生成都要去 Xcode 里再点一次。
import os
_tf = ROOT / ".developer_team"
DEV_TEAM = (os.environ.get("DEVELOPMENT_TEAM")
            or (_tf.read_text(encoding="utf-8").strip() if _tf.exists() else ""))

def uid(*parts):
    """24 位十六进制,Xcode 要求。由内容 hash 而来 → 幂等。"""
    return hashlib.sha1("::".join(parts).encode()).hexdigest()[:24].upper()

# ── 收集源文件(相对 SOURCE_ROOT)────────────────────────────────
def swift_files(rel_dir):
    d = ROOT / rel_dir
    return sorted(f"{rel_dir}/{p.name}" for p in d.glob("*.swift"))

APP_SRC    = swift_files("App")
ENGINE_SRC = swift_files("Sources/ReviewEngine")
SOURCES    = APP_SRC + ENGINE_SRC
# ★ Localizable.xcstrings 必须进 Resources,否则本地化整个不生效
#   (而且不会报错 —— 只会一直显示源语言,查半天)
RESOURCES  = ["App/Assets.xcassets", "App/Localizable.xcstrings"]
if not APP_SRC:    sys.exit("App/ 下没有 .swift")
if not ENGINE_SRC: sys.exit("Sources/ReviewEngine/ 下没有 .swift")

def ftype(path):
    if path.endswith(".swift"):     return "sourcecode.swift"
    if path.endswith(".xcassets"):  return "folder.assetcatalog"
    if path.endswith(".xcstrings"):  return "text.json.xcstrings"
    return "text"

# ── 组装 pbxproj ──────────────────────────────────────────────
PROJ_ID   = uid("project")
TARGET_ID = uid("target", APP_NAME)
PRODUCT_ID= uid("product", APP_NAME)
MAIN_GRP  = uid("group", "main")
PROD_GRP  = uid("group", "products")
APP_GRP   = uid("group", "App")
ENG_GRP   = uid("group", "Engine")
SRC_PHASE = uid("phase", "sources")
RES_PHASE = uid("phase", "resources")
FRM_PHASE = uid("phase", "frameworks")
CFG_PROJ  = uid("cfglist", "project")
CFG_TGT   = uid("cfglist", "target")

def refs_block():
    out = []
    for p in SOURCES + RESOURCES:
        out.append(f'\t\t{uid("ref", p)} /* {os.path.basename(p)} */ = {{isa = PBXFileReference; '
                   f'lastKnownFileType = {ftype(p)}; name = {os.path.basename(p)}; '
                   f'path = "{p}"; sourceTree = "<group>"; }};')
    out.append(f'\t\t{PRODUCT_ID} /* {APP_NAME}.app */ = {{isa = PBXFileReference; explicitFileType = '
               f'"wrapper.application"; includeInIndex = 0; path = "{APP_NAME}.app"; '
               f'sourceTree = BUILT_PRODUCTS_DIR; }};')
    return "\n".join(out)

def buildfiles_block():
    out = []
    for p in SOURCES:
        out.append(f'\t\t{uid("bf", p)} /* {os.path.basename(p)} in Sources */ = {{isa = PBXBuildFile; '
                   f'fileRef = {uid("ref", p)} /* {os.path.basename(p)} */; }};')
    for p in RESOURCES:
        out.append(f'\t\t{uid("bf", p)} /* {os.path.basename(p)} in Resources */ = {{isa = PBXBuildFile; '
                   f'fileRef = {uid("ref", p)} /* {os.path.basename(p)} */; }};')
    return "\n".join(out)

def group_children(paths):
    return "\n".join(f'\t\t\t\t{uid("ref", p)} /* {os.path.basename(p)} */,' for p in paths)

def phase_files(paths, kind):
    return "\n".join(f'\t\t\t\t{uid("bf", p)} /* {os.path.basename(p)} in {kind} */,' for p in paths)

BUILD_SETTINGS_COMMON = f"""
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = {DEPLOY_TGT};
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSWIFT_VERSION = 6.0;
\t\t\t\tSWIFT_STRICT_CONCURRENCY = complete;
"""

# 拆 f-string 会让后面的段落丢掉 f 前缀(踩过:{BUNDLE_ID} 原样写进了 pbxproj)。
# 所以预先算好整行,再插值进来。
TEAM_LINE = f"\n\t\t\t\tDEVELOPMENT_TEAM = {DEV_TEAM};" if DEV_TEAM else ""

TARGET_SETTINGS = f"""
\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
\t\t\t\tCODE_SIGN_STYLE = Automatic;{TEAM_LINE}
\t\t\t\tCURRENT_PROJECT_VERSION = {BUILD_NUMBER};
\t\t\t\tMARKETING_VERSION = {APP_VERSION};
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\t// ★ 改用真的 Info.plist:CFBundleDocumentTypes 是数组,
\t\t\t\t//   GENERATE_INFOPLIST_FILE 的 INFOPLIST_KEY_* 表达不了。
\t\t\t\tINFOPLIST_FILE = "App/Info.plist";
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "{BUNDLE_ID}";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1";   // 仅 iPhone:界面没为 iPad 设计过,声明支持会被「未针对 iPad 优化」拒。iPad 仍可装 iPhone 版,零损失
"""

PBX = f"""// !$*UTF8*$!
{{
\tarchiveVersion = 1;
\tclasses = {{}};
\tobjectVersion = 56;
\tobjects = {{

/* Begin PBXBuildFile section */
{buildfiles_block()}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{refs_block()}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
\t\t{FRM_PHASE} = {{
\t\t\tisa = PBXFrameworksBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = ();
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
\t\t{MAIN_GRP} = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{APP_GRP} /* App */,
\t\t\t\t{ENG_GRP} /* ReviewEngine */,
\t\t\t\t{PROD_GRP} /* Products */,
\t\t\t);
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{APP_GRP} /* App */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{group_children(APP_SRC + RESOURCES)}
\t\t\t);
\t\t\tname = App;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{ENG_GRP} /* ReviewEngine */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{group_children(ENGINE_SRC)}
\t\t\t);
\t\t\tname = ReviewEngine;
\t\t\tsourceTree = "<group>";
\t\t}};
\t\t{PROD_GRP} /* Products */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
\t\t\t\t{PRODUCT_ID} /* {APP_NAME}.app */,
\t\t\t);
\t\t\tname = Products;
\t\t\tsourceTree = "<group>";
\t\t}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
\t\t{TARGET_ID} /* {APP_NAME} */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {CFG_TGT};
\t\t\tbuildPhases = (
\t\t\t\t{SRC_PHASE},
\t\t\t\t{FRM_PHASE},
\t\t\t\t{RES_PHASE},
\t\t\t);
\t\t\tbuildRules = ();
\t\t\tdependencies = ();
\t\t\tname = "{APP_NAME}";
\t\t\tproductName = "{APP_NAME}";
\t\t\tproductReference = {PRODUCT_ID} /* {APP_NAME}.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{PROJ_ID} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 2600;
\t\t\t\tLastUpgradeCheck = 2600;
\t\t\t\tTargetAttributes = {{ {TARGET_ID} = {{ CreatedOnToolsVersion = 26.0; }}; }};
\t\t\t}};
\t\t\tbuildConfigurationList = {CFG_PROJ};
\t\t\tdevelopmentRegion = "zh-Hans";   // ★ 字面量就是中文,源语言必须是它
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = ( en, Base, "zh-Hans" );
\t\t\tmainGroup = {MAIN_GRP};
\t\t\tproductRefGroup = {PROD_GRP} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = ( {TARGET_ID} /* {APP_NAME} */, );
\t\t}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
\t\t{RES_PHASE} = {{
\t\t\tisa = PBXResourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{phase_files(RESOURCES, "Resources")}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
\t\t{SRC_PHASE} = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
{phase_files(SOURCES, "Sources")}
\t\t\t);
\t\t\trunOnlyForDeploymentPostprocessing = 0;
\t\t}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
\t\t{uid("cfg","proj","Debug")} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{{BUILD_SETTINGS_COMMON}\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;
\t\t\t\tENABLE_TESTABILITY = YES;
\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;
\t\t\t\tONLY_ACTIVE_ARCH = YES;
\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";
\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{uid("cfg","proj","Release")} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{{BUILD_SETTINGS_COMMON}\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;
\t\t\t\tVALIDATE_PRODUCT = YES;
\t\t\t}};
\t\t\tname = Release;
\t\t}};
\t\t{uid("cfg","tgt","Debug")} /* Debug */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{{TARGET_SETTINGS}\t\t\t}};
\t\t\tname = Debug;
\t\t}};
\t\t{uid("cfg","tgt","Release")} /* Release */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{{TARGET_SETTINGS}\t\t\t}};
\t\t\tname = Release;
\t\t}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
\t\t{CFG_PROJ} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = ( {uid("cfg","proj","Debug")} /* Debug */, {uid("cfg","proj","Release")} /* Release */, );
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
\t\t{CFG_TGT} = {{
\t\t\tisa = XCConfigurationList;
\t\t\tbuildConfigurations = ( {uid("cfg","tgt","Debug")} /* Debug */, {uid("cfg","tgt","Release")} /* Release */, );
\t\t\tdefaultConfigurationIsVisible = 0;
\t\t\tdefaultConfigurationName = Release;
\t\t}};
/* End XCConfigurationList section */
\t}};
\trootObject = {PROJ_ID} /* Project object */;
}}
"""

SCHEME = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES"
                           buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{TARGET_ID}"
               BuildableName = "{APP_NAME}.app" BlueprintName = "{APP_NAME}"
               ReferencedContainer = "container:{APP_NAME}.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES"/>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0"
      useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES"
      debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{TARGET_ID}"
            BuildableName = "{APP_NAME}.app" BlueprintName = "{APP_NAME}"
            ReferencedContainer = "container:{APP_NAME}.xcodeproj"/>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES"/>
   <AnalyzeAction buildConfiguration = "Debug"/>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
</Scheme>
"""

PROJ.mkdir(parents=True, exist_ok=True)
(PROJ / "project.pbxproj").write_text(PBX, encoding="utf-8")
sd = PROJ / "xcshareddata" / "xcschemes"; sd.mkdir(parents=True, exist_ok=True)
(sd / f"{APP_NAME}.xcscheme").write_text(SCHEME, encoding="utf-8")
print(f"✅ 生成 {PROJ}")
print(f"   App 源码 {len(APP_SRC)} 个 · 引擎源码 {len(ENGINE_SRC)} 个(与 swift test 共用同一批文件)")
print(f"   开发团队: {DEV_TEAM or '(未设置 —— 只能跑模拟器;装真机需在 Xcode 里选一次 Team,或写入 .developer_team)'}")
