# Secure Mode

`io.soloev/secure-mode`，Noctalia v5 / plugin API 46，依赖 `python3`（只使用标准库）和 `umbriel`。

## 工作方式

- 单个后台服务拥有开关状态、持久化文件及链接操作；多个屏幕的指示器共享同一状态。
- 第一次启动默认关闭。状态保存到 `noctalia.pluginDataDir()/state`，更新插件及重启后保留；每次服务启动会重新应用该状态，重建已被清空的临时链接。
- 开启：要求 `~/.config/umbriel/secure-mode.toml` 已存在，将其权限设为 `0400`，创建 `/tmp/io.soloev/secure-mode/secure-mode.toml -> ~/.config/umbriel/secure-mode.toml`。
- 关闭：只删除上述托管链接，保留源文件和源文件的 `0400` 权限。再次编辑源文件前，用户需自行恢复其写权限。
- 操作成功后才确认新状态。状态文件通过同目录临时文件原子替换；保存失败会尝试回滚链接。进程中断后，下次启动依据最后保存的状态恢复。
- 不覆盖普通文件、目录或指向其他目标的链接；异常会通知用户。未知状态显示警告，点击警告可重试恢复。不会自动循环重试。
- 每次开启、关闭或启动恢复，在文件操作完成后执行一次 `umbriel msg config-reload`；发生写入失败时，先完成清理/回滚，再重载最终文件状态。重载在同一操作锁内进行，完成前保持忙碌，不会与下次开关交错。
- 重载失败或超过 5 秒会通知用户，保留实际链接和已保存状态；可通过 `restore` 重试。用户仍需在 Umbriel 主配置中安排读取该配置片段；插件不修改主配置，也不监控外部编辑器的文件变更。

## 外观和操作

在栏上添加 **Secure Mode → indicator**。每个指示器实例可分别配置：

| 键 | 值 | 默认值 |
| --- | --- | --- |
| `style` | `dot` / `capsule`：开启时的小圆点 / 胶囊 | `dot` |
| `text` | 开启时胶囊文本 | `SECURE` |
| `close-style` | `hidden` / `capsule`：关闭时隐藏 / 浅色胶囊 | `hidden` |
| `close-text` | 关闭时胶囊文本 | `NORMAL` |

开启的圆点和胶囊使用主题 `error_container`；开启的胶囊文字使用 `on_error_container`。关闭的胶囊使用 `surface_container_high` 和 `on_surface_variant`。文本单行显示，最大宽度 160 逻辑像素。

点击指示器切换状态。操作中忽略后续点击，完成后可再次切换。关闭后隐藏时，从控制中心添加 **Secure Mode → toggle** 快捷开关，或使用服务 IPC：

```sh
noctalia msg plugin io.soloev/secure-mode:service all on
noctalia msg plugin io.soloev/secure-mode:service all off
noctalia msg plugin io.soloev/secure-mode:service all toggle
noctalia msg plugin io.soloev/secure-mode:service all restore
```

`restore` 重新应用已保存状态；状态未知时，点击指示器或控制中心开关也执行恢复。损坏的状态文件会被保留，需用户修复为 `enabled` 或 `disabled` 加换行，再恢复。

## 只读语义和边界

Linux 无法通过符号链接本身的权限建立只读访问：`chmod` 链接实际上修改目标。这里明确将**源文件设为 `0400`**，不创建可写副本。

`/tmp/io.soloev` 和其中的 `secure-mode` 目录均须属于当前用户且无组/其他用户权限，新建时使用 `0700`；已有目录权限不符时拒绝操作，不擅自修改。文件操作使用不跟随链接的打开方式和目录文件描述符，拒绝源文件为符号链接、特殊文件、非当前用户所有或有额外硬链接的情况。锁文件串行化跨进程操作。

这可以减少误写并阻止其他普通用户通过私有目录替换链接，**不能防御同 UID 的恶意进程或 root**。源文件所有者仍能重新 `chmod` 或替换源文件；要强制约束同一用户，必须另行使用权限隔离或只读挂载。插件不申请管理员权限，也不持续监控外部文件变动。

## 验证

在工作区根目录运行（harness 位于发布仓库之外）：

```sh
python3 -B harness/secure-mode/test_secure_mode.py -v
lua harness/secure-mode/plugin.lua
```

文件系统测试只使用 `/tmp/opencode/secure-mode-*` 内的模拟 HOME、数据目录和临时目录，并 mock 重载子进程，不读取或修改用户真实配置，也不会重载运行实例。Lua harness 使用 mock API，不能替代真实 Luau 和 GUI 验收。

用户人工验收：

1. 准备上述源配置文件，安装/启用插件并添加栏指示器和控制中心开关；首次应为关闭状态。
2. 用控制中心开关开启；检查圆点、链接方向、源文件 `0400` 和临时目录 `0700`。
3. 将 `style` 改为 `capsule` 并修改 `text`；应显示主题红色胶囊及自定义文字。
4. 关闭：`close-style=hidden` 应完全隐藏；改成 `capsule` 后显示独立 `close-text` 的浅色胶囊，运行链接已删除。
5. 分别在开启、关闭时重启 Noctalia；应恢复对应状态。多屏点击任一实例时其他实例及控制中心应同步。
6. 若使用竖向栏或很长的自定义文本，检查栏厚度下的实际裁切；可选用圆点或缩短文本。
7. 开启、关闭或重启恢复后，检查 Umbriel 依赖该配置片段的行为是否随重载生效；重载出错时应出现通知，可用 `restore` 重试。

删除/禁用插件不会自动关闭安全模式或删除现存链接；应先执行 `off`。临时目录及锁文件在关闭后保留，避免并发锁失效。
