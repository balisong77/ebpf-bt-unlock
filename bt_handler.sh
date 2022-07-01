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
