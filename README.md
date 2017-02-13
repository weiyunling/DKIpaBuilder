# DKIpaBuilder
iOS项目 hook + shell 自动打包 ipa 并上传到内测分发平台 fir.im

#### 前言

伴随着一年的 iOS 开发，最多的就是项目打包 ipa，然后上传到内测分发的平台如 fir.im 上去。时间长了，觉得这种毫无技术含量的人工操作太烦了，程序员就是要懂得偷懒，所以，我个人想出了一个好主意，通过摸索一步步证明我的想法是可行的，最后产出 Shell 脚本 DKIpaBuilder。

#### 为什么不采用 Jenkins

首先搞清楚 Jenkins 是什么。

[Jenkins](https://jenkins.io/index.html) 是一个开源项目，提供了一种易于使用的持续集成系统，使开发者从繁杂的集成中解脱出来，专注于更为重要的业务逻辑实现上。同时 Jenkins 能实施监控集成中存在的错误，提供详细的日志文件和提醒功能，还能用图表的形式形象地展示项目构建的趋势和稳定性。

根据官方定义，Jenkins 有以下的用途：

* 构建项目
* 跑测试用例检测bug
* 静态代码检测
* 部署

刚开始在思考持续构建问题的时候，在网上摸索得到最多的结果就是 Jenkins，各种持续集成如 Jenkins+Git+Maven+Shell+Tomcat、Gitlab+jenkins+shell、Jenkins+Git+Maven+tomcat 等等，不同领域都有着不一样的集成。但是，无一例外，集成的成本非常非常高，非常麻烦，出错也不好定位与解决。我尝试搭建，构建了几十次扔然失败，感觉有点绕，那么问题来了，绕在哪里？

思路是，基于 webHook，在基于 git 协议的托管平台上，每次收到 pull request 的时候往我们自己的服务器上 post 一个请求，服务器上用 nginx 反向代理到某个有 nodejs 监听的端口上，触发 shell 脚本 pull 项目代码，然后打包 ipa 并自动发布到内测分发平台上。

想法很美好，但是针对 iOS 来说，打包 ipa 必须要有 xcode 环境，而我们的 Ubuntu
 系统并不能安装 Xcode，最多通过安装 GNUSetp 来编译 Objective-C 的文件。换句话说，没有 mac 环境，用 Jenkins 也无法实现我们需求。 
 
现在我们需要一个 mac 服务器，但是租赁的价格非常昂贵。网上有人用 mac mini 来当 macOS 服务器，但是并不在外网环境，Coding、GitHub 等平台的 webHook 接收不到。
 
好了，又有人有想法了，既然不能被动接收 post 请求，那就反过来主动轮询 Coding 等平台上面的分支，如果发现有新的 commit，就触发接下来的一系列事件。如果要足够时效性，轮询的时间间隔可能还要考虑1分钟左右，（远程托管平台 : 虽然我不会奔溃，但我鄙视你）。看似可行，但是问题又来了，打包的时间好久。
 
因为 mini 是机械硬盘，读写速度慢，打包可能要好几分钟，大一点的项目可能要十几分钟，如果 CocoaPods 安装了很大的第三方库或者 OC 与 Swift 混编的时候，甚至只是 storyboard 和 xib 文件非常多的时候，可能会打包几十分钟。这很坑爹啊，明明我自己的电脑是 macBook Pro，有着256G的固态硬盘，为什么我要绕到 mini 去打包？
 
另外，明明我的 Xcode 已经什么都配好了，我想省掉的只是每次 Archive 都要经过的那几个步骤，为什么我要重新配 mini 上的环境，还要配 Jenkins 里的 provisioning Profile，还要配什么钥匙串，讲道理，不绕吗？

出于以上的以及其它的种种问题，最终我不采用 Jenkins 来持续集成，至少针对 iOS 我是拒绝的，这个时候需要想些别的办法。

#### pre-push hook

于是我想到了个办法，换个思想，先打包ipa，上传到分发平台，然后才push。这样的话，操作完全是在本机，不需要服务器。而相关的配置，只要在 Xcode 中配置好，确定本地可以手动打包，就可以通过命令行来实现。

把 push 放在最后是很巧妙的！在[《解决iOS项目文件合并.xcodeproj冲突》](https://bingo.ren/2017/02/09/11/)中，用 xUnique 去解决问题，切入点就是 hooks，选择的是 pre-commit。这种情况不适合 pre-commit，而应该选择 pre-push。这样就可以用 pre-push 这个钩子来先调用 Shell 脚本。对我们而言，不需要敲什么别的命令，只要一句非常普通的 push 命令。

开始写 pre-push，先在项目根目录创建一个 Shell 文件，并在 pre-push 中写入执行它。

```
$ cd to/path/project 
$ touch DKIpaBuilder.sh
$ chmod 777 DKIpaBuilder.sh
$ { echo '#!/bin/sh'; echo './DKIpaBuilder.sh'; } > .git/hooks/pre-push
```

#### DKIpaBuilder.sh

前面的触发器已经搭建好了，现在的重点已经转移到后续工作了，如何用命令行去打包 ipa，并上传到 fir.im。

用命令行打包是重点，也是 Jenkins 帮用户搞定的部分中最难的一部分，众所周知的是用 Xcode 自带的 Command Line Tools。顺便说一下这个 shell 脚本依赖的环境。

* MacOS 10.9+ 
* Xcode 6.0 or later and Command Line Tools 
* WorkSpace 工程，例如使用了 Cocoapods 依赖库管理的工程
* 配置好开发证书和 Ad Hoc 证书（for Debug）和（for Release），建议在 Xcode 中选择 Automatically manage signing
* 工程中配置好 Scheme 并勾上 Shared

好了，接下来上脚本源码，大概分为以下几步：

**shell config**

```
# target name
target_name="SF"

# workspace name
build_workspace="${target_name}.xcworkspace" 

# project name and path
project_path=$(pwd)
project_name=$(ls | grep xcodeproj | awk -F.xcodeproj '{print $1}')

# provisiong profile name
provisioningProfile='"XC iOS Ad Hoc: cn.dankal.${target_name}"'

# fir token
fir_token="19cbd0975bf5099b68a045a73a5c4fe2"

# scheme name
build_scheme="SF" 

# build config. the default is Debug|Release
build_config="Release"
```

**clean**

```
# clean build
echo "****** DKIpaBuilder: 开始清理构建缓存 ******"
clean_cmd='xcodebuild'
clean_cmd=${clean_cmd}' clean -workspace '${build_workspace}' -scheme '${build_scheme}' -configuration '${build_config}
$clean_cmd >  $build_path/clean.log || exit
```

**build & archive, generate the archive file**

```
echo "****** DKIpaBuilder: 清理构建缓存文件完毕，开始归档 ******"
archive_name="${target_name}_${timeStamp}.xcarchive"
archive_path=${build_path}/$archive_name 
build_cmd='xcodebuild'
build_cmd=${build_cmd}' -workspace '${build_workspace}' -scheme '${build_scheme}' -destination generic/platform=iOS archive -configuration '${build_config}' ONLY_ACTIVE_ARCH=NO -archivePath '${archive_path}
echo "****** DKIpaBuilder: 归档完成，开始导出归档文件，路径:${archive_path} ******"

$build_cmd > $build_path/archive.log || exit

if [ ! -d "${archive_path}" ]; then
    echo  "****** DKIpaBuilder: 归档失败! 请查看日志文件，路径:${build_path}/archive.log. ******"
    exit 2
else
    echo "****** DKIpaBuilder: 归档完成，路径:${archive_path} ******"
fi 
```

**export to ipa**

```
# export to ipa 
ipa_name="${target_name}_ADHoc_${timeStamp}.ipa"
ipa_path=${build_path}/$ipa_name 

ipa_cmd='xcodebuild'
ipa_cmd=${ipa_cmd}' -exportArchive -exportFormat ipa -archivePath '${archive_path}' -exportPath '${ipa_path}' -exportProvisioningProfile '${provisioningProfile}

echo "****** DKIpaBuilder: 开始导出ipa文件，路径:${ipa_path} ******"
# echo ${ipa_cmd}
eval ${ipa_cmd} > $build_path/export.log || exit

if [ ! -f "${ipa_path}" ]; then
    echo  "****** DKIpaBuilder: 导出ipa失败，请查看日志文件，路径:${build_path}/export.log. ******"
    exit 2
else
    echo "****** DKIpaBuilder: 导出ipa完成，路径:${ipa_path} ******"
fi
```

**upload to fir.im**

```
echo "****** DKIpaBuilder: 即将上传 ipa 到 fir.im ******"
# 上传ipa到fir
fir login ${fir_token}
echo "****** DKIpaBuilder: 解析 ipa ******"
fir i ${ipa_path}
echo "****** DKIpaBuilder: 上传 ipa ******"
fir p ${ipa_path}
echo "****** DKIpaBuilder: 上传成功，构建任务已完成！******"
```

#### 运行结果

贴上一行 push 代码后的完整 log。

```
Bingos-MacBook-Pro:SF bingo$ git push origin master
mkdir: ./build: File exists
****** DKIpaBuilder: 开始构建任务，当前版本【0.2.4】，构建号【1】 ******
****** DKIpaBuilder: 开始清理构建缓存 ******
2017-02-12 18:32:57.082 xcodebuild[15249:206686] [MT] DVTPlugInManager: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for KSImageNamed.ideplugin (com.ksuther.KSImageNamed) not present
2017-02-12 18:32:57.134 xcodebuild[15249:206686] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/VVDocumenter-Xcode.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:32:57.134 xcodebuild[15249:206686] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/SCXcodeSwitchExpander.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:32:57.134 xcodebuild[15249:206686] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/DXXcodeConsoleUnicodePlugin.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:32:57.135 xcodebuild[15249:206686] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/CocoaPods.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:32:57.135 xcodebuild[15249:206686] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/Alcatraz.xcplugin' not present in DVTPlugInCompatibilityUUIDs
****** DKIpaBuilder: 清理构建缓存文件完毕，开始归档 ******
****** DKIpaBuilder: 归档完成，开始导出归档文件，路径:./build/SF_2017-02-12-18-32-56.xcarchive ******
2017-02-12 18:32:59.697 xcodebuild[15262:206786] [MT] DVTPlugInManager: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for KSImageNamed.ideplugin (com.ksuther.KSImageNamed) not present
2017-02-12 18:32:59.750 xcodebuild[15262:206786] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/VVDocumenter-Xcode.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:32:59.751 xcodebuild[15262:206786] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/SCXcodeSwitchExpander.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:32:59.751 xcodebuild[15262:206786] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/DXXcodeConsoleUnicodePlugin.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:32:59.751 xcodebuild[15262:206786] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/CocoaPods.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:32:59.751 xcodebuild[15262:206786] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/Alcatraz.xcplugin' not present in DVTPlugInCompatibilityUUIDs
****** DKIpaBuilder: 归档完成，路径:./build/SF_2017-02-12-18-32-56.xcarchive ******
****** DKIpaBuilder: 开始导出ipa文件，路径:./build/SF_ADHoc_2017-02-12-18-32-56.ipa ******
--- xcodebuild: WARNING: -exportArchive without -exportOptionsPlist is deprecated
2017-02-12 18:33:44.754 xcodebuild[18059:212703] [MT] DVTPlugInManager: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for KSImageNamed.ideplugin (com.ksuther.KSImageNamed) not present
2017-02-12 18:33:44.810 xcodebuild[18059:212703] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/VVDocumenter-Xcode.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:33:44.810 xcodebuild[18059:212703] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/SCXcodeSwitchExpander.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:33:44.811 xcodebuild[18059:212703] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/DXXcodeConsoleUnicodePlugin.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:33:44.811 xcodebuild[18059:212703] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/CocoaPods.xcplugin' not present in DVTPlugInCompatibilityUUIDs
2017-02-12 18:33:44.811 xcodebuild[18059:212703] [MT] PluginLoading: Required plug-in compatibility UUID E0A62D1F-3C18-4D74-BFE5-A4167D643966 for plug-in at path '~/Library/Application Support/Developer/Shared/Xcode/Plug-ins/Alcatraz.xcplugin' not present in DVTPlugInCompatibilityUUIDs
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
1.2.840.113635.100.1.61
****** DKIpaBuilder: 导出ipa完成，路径:./build/SF_ADHoc_2017-02-12-18-32-56.ipa ******
****** DKIpaBuilder: 即将上传 ipa 到 fir.im ******
I, [2017-02-12T18:33:51.994670 #18073]  INFO -- : Login succeed, previous user's email: bingo@dankal.cn
I, [2017-02-12T18:33:51.997097 #18073]  INFO -- : Login succeed, current  user's email: bingo@dankal.cn
I, [2017-02-12T18:33:51.997139 #18073]  INFO -- : 
****** DKIpaBuilder: 解析 ipa ******
I, [2017-02-12T18:33:52.537591 #18077]  INFO -- : Analyzing ipa file......
I, [2017-02-12T18:33:52.537691 #18077]  INFO -- : ✈ -------------------------------------------- ✈
security: SecPolicySetValue: One or more parameters passed to a function were not valid.
I, [2017-02-12T18:33:53.494898 #18077]  INFO -- : type: ios
I, [2017-02-12T18:33:53.495004 #18077]  INFO -- : identifier: cn.dankal.SF
I, [2017-02-12T18:33:53.495027 #18077]  INFO -- : name: SF
I, [2017-02-12T18:33:53.495049 #18077]  INFO -- : display_name: 顺丰大当家
I, [2017-02-12T18:33:53.495071 #18077]  INFO -- : build: 1
I, [2017-02-12T18:33:53.495087 #18077]  INFO -- : version: 0.2.4
I, [2017-02-12T18:33:53.495189 #18077]  INFO -- : devices: ["8912698044eeacb3d12426f4e9a1469fd060fbaf", "b45b74ee7c93cbe95a4b9df9b8914a6c2f502800", "298c6e6325e6c580198d98732eb2212912989fc7", "9269a1abd383b440c3f1c5aa97a8c06be6b858b6", "939c0a3464a486657a450ac629d42939d714bed0", "e984ef9183f24f541cdd8f22161d628ff6519fd2", "056e23a5ba30dd2181d90507bde9bcb9442afdee", "b4b1d7b6828778f60adc59843be9ec8060d9ac2c", "cb3a1628b15fa0b39c0b7eee8487fae97ba57b41", "8517325a2ee1b640a61b6592da11908fdb6d6ff2", "010dece24480cf968750835a94aaecc566094f53", "ba591cecf0c36271c54a3fadf6a07a44e0e4f4d0", "d8a32422afa0aa1b58644733776f6d2f3f04203c", "0b72cd659b790b54a0eaa2f49806f38a9633638e", "9ba116a06f5071e32f46962fc866fe037bbfe9fa", "31a273dc5209aacfea6d787c93574dec4ea2172d", "aa8c668fede84bec8c0399e7e5669f42f9afdbc7", "31681d5b2da1a09795608732090df5ba6ba26dee", "df4b23976e7f63cdcb1a0fd73cdf17ff3b7b5795", "3e3dcc6db1b20c4439ba260a43b047a7ac6a8fd0", "85463ba4d3616542f7944ca41709b06f64dca5c1", "e340f9e6cdc8411d05449f689bb018c36f1981a9", "a1c4cdc6c7da483ca4f80fb5589713ba3c9cb7a1", "6c3ed2b3fefe74c611ac5b32c43a082c4c5bc3e3", "33438fc50f576b8d60c8c3182788b787a012182c", "72e1a4e155e6bfa84e08aec1fb36c1c67e3025d1", "e60330cdb817e00578d46cff328983fce5bb072e", "289bbfc7681ccf074d3fbd4037f0bcb6e855354f", "f21f49939ffb74a4018dce8f64f85387623a0556", "6782a38eff5b46cca0275dd903953b656a7dda43", "df72fe073cd77571f6a2e1b38b9ffd0c04a1ef94", "5887e732dcd301676690bae14e0b5822db35dabd", "930bab0f435ffcad8e77655f3d5fae5ed073e0ce", "096cb4be2e4bc3391d819920fb988422a9f3c8b5", "8e2476617934cb439ab5c560cf05e38e6bdbaf88", "7d075e37eabced973af3d061be342620c5f21d52", "fe019811c542ba411d87d14717d569d1f11f7bb1", "3e69212a532b24ecac40e3f0039609101fb538eb"]
I, [2017-02-12T18:33:53.495286 #18077]  INFO -- : release_type: adhoc
I, [2017-02-12T18:33:53.495318 #18077]  INFO -- : distribution_name: XC iOS Ad Hoc: cn.dankal.SF - Shenzhen Dankal Creative Technology Co., Ltd.
I, [2017-02-12T18:33:53.495345 #18077]  INFO -- : 
****** DKIpaBuilder: 上传 ipa ******
I, [2017-02-12T18:33:54.876226 #18082]  INFO -- : Publishing app via bingo<bingo@dankal.cn>.......
I, [2017-02-12T18:33:54.876368 #18082]  INFO -- : ✈ -------------------------------------------- ✈
security: SecPolicySetValue: One or more parameters passed to a function were not valid.
I, [2017-02-12T18:33:55.871057 #18082]  INFO -- : Fetching cn.dankal.SF@fir.im uploading info......
I, [2017-02-12T18:33:55.871157 #18082]  INFO -- : Uploading app: SF-0.2.4(Build 1)
I, [2017-02-12T18:33:56.097807 #18082]  INFO -- : Uploading app icon......
I, [2017-02-12T18:33:56.097972 #18082]  INFO -- : Converting app's icon......
I, [2017-02-12T18:33:56.705341 #18082]  INFO -- : Uploading app binary......
I, [2017-02-12T18:42:27.814654 #18082]  INFO -- : Updating devices info......
I, [2017-02-12T18:42:27.940879 #18082]  INFO -- : Fetch app info from fir.im
I, [2017-02-12T18:42:28.074969 #18082]  INFO -- : ✈ -------------------------------------------- ✈
I, [2017-02-12T18:42:28.075039 #18082]  INFO -- : Published succeed: http://fir.im/sfddj
I, [2017-02-12T18:42:28.075068 #18082]  INFO -- : 
****** DKIpaBuilder: 上传成功，构建任务已完成！******
Counting objects: 67, done.
Delta compression using up to 8 threads.
Compressing objects: 100% (65/65), done.
Writing objects: 100% (67/67), 20.67 KiB | 0 bytes/s, done.
Total 67 (delta 43), reused 0 (delta 0)
To https://git.coding.net/dankal2188/SF.git
   3d4cad5..bd6de73  master -> master
Bingos-MacBook-Pro:SF bingo$ 
```

#### 补充

用命令行上传 ipa 到 fir.im 是没有更新日志的，需要手动到平台网页去编辑更新日志。但这也不是事儿，把 git commit 的 message 拷贝粘贴过去就是了，也就鼠标点几下子的事。（这也嫌麻烦？无解了，Jenkins 也不帮不了你）

#### 后话

对于每一个新项目，只需要修改 DKIpaBuilder.sh 的前面的几个配置，并且创建一个 pre-push 的 hook，配置过程5分钟不到，一句 git push 即可打包并上传到 fir.im，你还想用 Jenkins 吗？如果您有更好的解决方案，欢迎 Issues。