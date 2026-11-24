# Frida Local

在 Roothide iPhone 上管理和运行 Frida JavaScript。Frida Local 连接本机的 `frida-server`，可对设备上的任意第三方 App 或进程运行脚本。

## 使用

1. 安装 `packages/dev.fridalocal_0.2.9_iphoneos-arm64e.deb`。安装完成后会启动所选版本的 `frida-server`，然后即可打开 **Frida Local**。
2. 在「设置」的「Frida Server」中查看状态、启停服务或修改监听设置。首次安装默认监听 `127.0.0.1:27042`。也可选择 `0.0.0.0`（所有 IPv4 接口），地址与端口一起保存。
3. 在「脚本」从「文件」导入一个 UTF-8 `.js`，或使用「导入示例」。
4. 打开脚本。**Attach** 选择运行中的进程，**Spawn** 选择已安装的应用。默认仅显示第三方 App 及其进程。可在目标选择页关闭「仅第三方 App」，然后搜索或浏览全部目标（含系统进程）。选中任意目标即可运行。
5. 在弹窗的「文件」区选择「查看」，可以在 Filza 定位脚本的 `.js` 副本。 [Filza 使用指南](https://www.tigisoftware.com/default/?page_id=177)
6. Attach 或 Spawn 成功后，屏幕浮层会显示当前脚本、运行时间和实时日志。拖动标题栏可以移动浮层，点右上方的停止按钮可以结束会话。停止按钮左侧可依次切换「展开」「单行」「隐藏」日志。单行模式显示最新一条，超出宽度时会横向滚动。会话结束后浮层自动关闭，「日志」页仍可查看输出、异常和退出事件。浮层和「日志」页均支持 ANSI 颜色。
7. 在「设置」的「运行浮层」中可调整并保存浮层背景透明度。正在显示的浮层会立即更新，文字和按钮保持清晰。

安装或更新含浮层的版本后，重启 SpringBoard（Respring）以加载浮层。

## 选择 Frida 版本

进入「设置」→「版本」，再进入「Frida 16」或「Frida 17」。每个类别分别缓存最新 10 个官方 iOS arm64 正式包的版本和下载地址。下拉刷新当前类别，也可临时加载更早的版本或搜索完整版本号。 [GitHub 发行列表](https://github.com/frida/frida/releases)

未下载的版本显示下载图标，点击后可在图标处查看进度。下载完成后，图标变为切换，点选即可启用该版本。当前版本用绿色勾号标记。已下载的版本可离线切换。服务运行时会沿用现有监听端口，切换失败时恢复原服务。切换前需要停止当前脚本会话。

使用 Frida 17 时，依赖 `ObjC`、`Swift` 等 runtime bridge 的脚本需将相应 bridge 打入所导入的 `.js` 文件。 [Frida Runtime Bridges](https://frida.re/docs/bridges/)

## 构建

在装有 Roothide Theos、Xcode、`ldid` 和 `dpkg-deb` 的 Mac 上运行。

```sh
make deps
make clean
make package FINALPACKAGE=1
```

`make deps` 下载并验证 Frida 16.7.19、17.27.4 的 iOS Core SDK，以及默认的 17.27.4 服务端。发行包包含两个协议主版本的客户端和服务管理 helper。安装或升级时沿用已保存的版本和监听设置。 [Frida 17.27.4 发行文件](https://github.com/frida/frida/releases/tag/17.27.4)

真机自动化验收入口在清理构建目录后通过 `make package FINALPACKAGE=1 DEVICE_SMOKE=1` 编译。验收构建安装后，以设备的 `mobile` 用户运行 `/Applications/FridaLocal.app/FridaLocal --device-smoke`。也可用 `--catalog-smoke` 验证 GitHub 刷新、下载和跨版本脚本会话，用 `--listener-smoke` 验证监听设置与启动日志，或用 `--targets-smoke` 验证目标列表和 Filza 文件链接。清理后重新执行正常构建即可生成正式包。
