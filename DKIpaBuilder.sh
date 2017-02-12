#!/bin/bash
#
#  DKIpaBuilder
#  iOS项目自动打包ipa，并发布到内测分发平台fir.im
#
#  Created by 庄槟豪 on 2017/2/12.
#  Copyright © 2017年 cn.dankal. All rights reserved.
#

# init build configuration
build_path="./build"
if [ ! -d build_path ]; then
  mkdir ${build_path}
fi

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

# timestamp for ouput file name
timeStamp="$(date +"%Y-%m-%d-%H-%M-%S")"

# echo "$project_path/$build_workspace"
if [ ! -d "$project_path/$build_workspace" ]; then
    echo  "Error!Current path is not a xcode workspace.Please check, or do not use -w option."
    exit 2
fi 

# get the info.plist
app_infoplist_path=${project_path}/${project_name}/info.plist

# get the main version
bundleShortVersion=$(/usr/libexec/PlistBuddy -c "print CFBundleShortVersionString" "${app_infoplist_path}")

# get the build version
bundleVersion=$(/usr/libexec/PlistBuddy -c "print CFBundleVersion" "${app_infoplist_path}")

echo "****** DKIpaBuilder: 开始构建任务，当前版本【${bundleShortVersion}】，构建号【${bundleVersion}】 ******"

# scheme name
build_scheme="SF" 

# build config. the default is Debug|Release
build_config="Release"

# clean build
echo "****** DKIpaBuilder: 开始清理构建缓存 ******"
clean_cmd='xcodebuild'
clean_cmd=${clean_cmd}' clean -workspace '${build_workspace}' -scheme '${build_scheme}' -configuration '${build_config}
$clean_cmd >  $build_path/clean.log || exit

# build & archive, generate the archive file
echo "****** DKIpaBuilder: 清理构建缓存文件完毕，开始归档 ******"
archive_name="${target_name}_${timeStamp}.xcarchive"
archive_path=${build_path}/$archive_name 
build_cmd='xcodebuild'
build_cmd=${build_cmd}' -workspace '${build_workspace}' -scheme '${build_scheme}' -destination generic/platform=iOS archive -configuration '${build_config}' ONLY_ACTIVE_ARCH=NO -archivePath '${archive_path}
echo "****** DKIpaBuilder: 归档完成，开始导出归档文件，路径:${archive_path} ******"
# echo ${build_cmd}
$build_cmd > $build_path/archive.log || exit

if [ ! -d "${archive_path}" ]; then
    echo  "****** DKIpaBuilder: 归档失败! 请查看日志文件，路径:${build_path}/archive.log. ******"
    exit 2
else
    echo "****** DKIpaBuilder: 归档完成，路径:${archive_path} ******"
fi 

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
    # 导出ipa成功的时候清除没有必要存在的日志文件
    rm ${build_path}/*.log
    rm -r ${build_path}/*.xcarchive

    echo "****** DKIpaBuilder: 即将上传 ipa 到 fir.im ******"
    # 上传ipa到fir
    fir login ${fir_token}
    echo "****** DKIpaBuilder: 解析 ipa ******"
    fir i ${ipa_path}
    echo "****** DKIpaBuilder: 上传 ipa ******"
    fir p ${ipa_path}
    echo "****** DKIpaBuilder: 上传成功，构建任务已完成！******"
fi 
