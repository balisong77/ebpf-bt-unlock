基于bpftrace实现用蓝牙解锁/锁定电脑

# 实验要求

使用`bpftrace`对蓝牙连接，断开等系统调用函数进行监测，并以此为挂载点，开发自定义的功能。从而实现指定设备因远离而导致蓝牙断开时锁屏，设备靠近后蓝牙重新连接后解锁。

# 实验环境

```
OS: Ubuntu 22.04 LTS x86_64 
Kernel: 5.15.0-40-generic
```

> 这里不建议使用WSL2进行`eBpf`开发，因为WSL2虽然是基于Hyper-V的虚拟机，拥有完整的Linux内核，但其内核是经过微软定制的，安装`bpftrace`环境非常折腾，而且对`bpftrace`的支持不是很好

# 实验过程

1. 使用`trace-cmd`来找出蓝牙相关的系统调用函数

执行

```bash
trace-cmd record -p function -l ':mod:bluetooth'
```

对蓝牙模块的函数调用进行监控

![image-20220703233637642](https://lunqituchuang.oss-cn-hangzhou.aliyuncs.com/image-20220703233637642.png)

一段时间后Ctrl+C终止监听，使用

```bash
trace-cmd report
```

查看监听结果，可以看到本文要使用的`kprobe`点`mgmt_device_found`和`mgmt_device_disconnected`分别在检测到蓝牙设备，和蓝牙断开连接时被调用

![image-20220703234941007](https://lunqituchuang.oss-cn-hangzhou.aliyuncs.com/image-20220703234941007.png)

![image-20220703234729041](https://lunqituchuang.oss-cn-hangzhou.aliyuncs.com/image-20220703234729041.png)

两个函数的定义如下

```c
void mgmt_device_found(struct hci_dev *hdev, bdaddr_t *bdaddr, u8 link_type,
		       u8 addr_type, u8 *dev_class, s8 rssi, u32 flags,
		       u8 *eir, u16 eir_len, u8 *scan_rsp, u8 scan_rsp_len)
{
```

```c
int mgmt_device_disconnected(struct hci_dev *hdev, bdaddr_t *bdaddr,
			     u8 link_type, u8 addr_type, u8 reason);
```

第一个参数`struct hci_dev hdev`保存了蓝牙设备的相关信息，可以获得蓝牙设备的MAC地址，参数`s8 rssi`代表了蓝牙设备的当前信号强度，结构体定义如下

```c
struct hci_dev {
	struct list_head list;
	struct mutex	lock;
    ...
	char		name[8];
}
```



2. 使用`bpftrace`对系统调用函数的参数进行实时监控

查看两函数在`bpftrace`属于哪类挂载点

```bash
sudo bpftrace -l '*mgmt_device*'
```

![image-20220704000354856](https://lunqituchuang.oss-cn-hangzhou.aliyuncs.com/image-20220704000354856.png)

编写`bpftrace`脚本`bt_rssi.bt`对蓝牙设备进行检测，获取其MAC地址和信号强度

```bash
# bt_rssi.bt
#!/snap/bin/bpftrace

kprobe:mgmt_device_found
{
$mac1=*(arg1+3) & 0xffffff;
$mac2=*(arg1) & 0xffffff;
printf("%X%X %d\n", $mac1,$mac2, arg5);
}
```

编写脚本`bt_disconnect.bt`获取断开连接的蓝牙设备MAC地址

```bash
# bt_disconnect.bt
#!/snap/bin/bpftrace

kprobe:mgmt_device_disconnected
{
$mac1=*(arg1+3) & 0xffffff;
$mac2=*(arg1) & 0xffffff;
printf("%X%X\n", $mac1,$mac2)
;
}
```

3. 根据上述`bpftrace`脚本获取到的蓝牙设备状况，使用Bash脚本编写控制逻辑，控制电脑的锁屏

```bash
# bt_handler.sh
#!/usr/bin/env bash

# 执行此脚本传入的参数，是你用来解锁电脑的设备的蓝牙MAC地址
TARGET_MAC=$1
# 该文件用来判断电脑是否处于锁定状态
LOCKFILE=bt.lock

bt_lock() {
# args是变量数组，args[0]是Mac地址，args[1]是信号强度
args=($1)
# 如果MAC地址匹配
if [ "${args[0]}" == "$TARGET_MAC" ]
then
  # 如果信号强度小于-55 且LOCKFILE不存在（即电脑当前未锁定）
  if [ "${args[1]}" -lt -55 ] && [ ! -f "$LOCKFILE" ]
  then
    # 创建LOCKFILE文件并将电脑锁定
    >"$LOCKFILE"
    echo "locked"
    loginctl lock-sessions
  fi
  # 如果信号强度大于-45 且电脑已锁定，则解锁电脑
  if [ "${args[1]}" -gt -45 ] && [ -f "$LOCKFILE" ]
  then
    #删除LOCKFILE并将电脑解锁
    rm -f "$LOCKFILE"
    echo "unlocked"
    loginctl unlock-sessions
  fi
fi
}
# 将变量暴露给后续命令使用
export TARGET_MAC
export LOCKFILE
export -f bt_lock

# 使用./bt_disconnect.bt来检测target蓝牙是否断开，如果断开则将电脑锁定
bpftrace ./bt_disconnect.bt | grep --line-buffered "$TARGET_MAC" | xargs -r -n1 bash -c ">$LOCKFILE;echo disconnected; loginctl lock-sessions" &  
# 使用./bt_rssi.bt 来检测target蓝牙信号强度，并调用上面定义的bt_lock()函数进行逻辑判断
bpftrace ./bt_rssi.bt | xargs -r -n1 -I '{}' bash -c 'bt_lock "$@"' _ {}

```

# 实验效果

同时运行`bt_rssi.bt`和`bt_handler.sh`两个脚本，观察运行效果和程序的输出。在两个terminal中分别执行（两个脚本的参数为你控制电脑的蓝牙设备的MAC地址，这里我使用我手机的MAC地址E06D176B4C9）

```bash
sudo bpftrace ./bt_rssi.bt | grep E06D176B4C9

sudo ./bt_handler.sh E06D176B4C9
```

运行效果截图如下，左边终端输出电脑锁定情况，右边终端输出蓝牙设备的信号强度：

1. 在右边终端可以看到当前手机的蓝牙信号强度为-45，比-55大，不会锁定电脑

![11](https://lunqituchuang.oss-cn-hangzhou.aliyuncs.com/11.png)

2. 当把手机拿远后，信号强度小于-55时，电脑会自动锁屏，左边终端会输出locked表示电脑已锁定。而将手机拿近后，信号强度大于-45时，电脑则会自动解锁，并在左边终端输出unlocked。

![22](https://lunqituchuang.oss-cn-hangzhou.aliyuncs.com/22.png)

3. 如果此时把手机蓝牙关闭，电脑也会自动锁屏，并输出disconnected。再次把蓝牙打开，手机会自动连接电脑蓝牙，并使电脑解锁，输出unlocked。

![33](https://lunqituchuang.oss-cn-hangzhou.aliyuncs.com/33.png)

综上所述，本实验的目的已经圆满实现。

# 实验总结

通过对蓝牙连接和断开时的系统函数调用流程分析，找出了`mgmt_device_found`和`mgmt_device_disconnected`两个挂载点。并根据两函数的定义，可以从其参数中获取蓝牙设备的MAC地址供我们监控使用。辅助以脚本的逻辑流程控制，可以轻而易举地实现通过蓝牙连接和断开控制电脑锁屏地功能。通过本实验了解了`bpftrace`工具的一些基础语法和用法。了解了寻找挂载点的方法，能从该挂载点中获取到什么信息。通过此直观的实验初次体验到了`eBpf`的强大和神奇之处，

实验中遇到的一些问题有：

1. 注意修改系统设置，电脑锁屏后要保证蓝牙连接不会中断。
2. KDE桌面环境下，`mgmt_device_found`系统调用只有在打开蓝牙搜索界面时才会被定时地调用，运行此实验时要保证蓝牙搜索界面的打开。

# 附录

因为实验效果光凭截图无法直观的体验和感受，所以录制了演示视频供参考。

实验效果演示视频地址https://www.bilibili.com/video/BV1Qr4y1g7rc

本实验所使用的代码仓库地址https://github.com/balisong77/ebpf-bt-unlock

