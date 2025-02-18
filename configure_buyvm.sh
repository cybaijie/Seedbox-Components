#!/bin/bash

# 检查root权限
if [ "$(id -u)" != "0" ]; then
   echo "请使用 root 用户或 sudo 运行此脚本" 
   exit 1
fi

# 定义变量
USERNAME=""
PASSWORD=""
RAID0=false

# 参数处理
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--username)
      USERNAME="$2"
      shift 2
      ;;
    -p|--password)
      PASSWORD="$2"
      shift 2
      ;;
    -r0|--raid0)
      RAID0=true
      shift
      ;;
    *)
      echo "未知参数: $1"
      exit 1
      ;;
  esac
done

# 验证必要输入
if [ -z "$USERNAME" ]; then
  read -p "请输入用户名: " USERNAME
fi
if [ -z "$PASSWORD" ]; then
  read -s -p "请输入密码: " PASSWORD
  echo
fi

# 安装基础软件
apt-get update
apt-get -y install vim util-linux wget mdadm

# 设置SWAP
setup_swap() {
  swap_size=$(free -m | awk '/Swap/{print $2}')
  if [ "$swap_size" -ne 0 ]; then
    echo "检测到已存在Swap空间，跳过创建"
    return
  fi

  echo "正在创建Swap文件..."
  if fallocate -l 1G /swapfile && \
     chmod 600 /swapfile && \
     mkswap /swapfile && \
     swapon /swapfile; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo "Swap创建成功"
    free -h
  else
    echo "Swap创建失败！"
    exit 1
  fi
}

setup_swap

# 磁盘处理函数
create_raid0() {
  local disks=("$@")
  echo "正在创建RAID0阵列..."
  
  # 验证所有磁盘存在
  for disk in "${disks[@]}"; do
    if [ ! -e "$disk" ]; then
      echo "错误：磁盘 $disk 不存在！"
      exit 1
    fi
  done

  # 清除现有数据和文件系统
  for disk in "${disks[@]}"; do
    umount "${disk}" 2>/dev/null || true
    wipefs -a "${disk}"
    mdadm --zero-superblock "${disk}" 2>/dev/null || true
  done

  # 创建RAID阵列
  if ! mdadm --create --verbose /dev/md0 --level=0 --raid-devices=${#disks[@]} "${disks[@]}" --force; then
    echo "RAID0创建失败！"
    exit 1
  fi

  # 格式化文件系统
  mkfs.ext4 -F /dev/md0

  # 挂载配置
  MOUNT_DIR="/home/${USERNAME}/qbittorrent/Downloads"
  mkdir -p "$MOUNT_DIR"
  mount -o discard,defaults /dev/md0 "$MOUNT_DIR"
  chmod -R 777 "$MOUNT_DIR"

  # 持久化配置
  mdadm --detail --scan >> /etc/mdadm/mdadm.conf
  update-initramfs -u
  echo "/dev/md0 $MOUNT_DIR ext4 defaults,nofail,discard 0 0" >> /etc/fstab

  echo "RAID0创建并挂载完成"
  mdadm --detail /dev/md0
}

mount_disk() {
  local disk=$1
  echo "正在处理磁盘: $disk"
  
  # 清除现有数据
  umount "${disk}" 2>/dev/null || true
  wipefs -a "${disk}"
  
  # 格式化并挂载
  mkfs.ext4 -F "$disk"
  MOUNT_DIR="/home/${USERNAME}/qbittorrent/Downloads"
  mkdir -p "$MOUNT_DIR"
  mount -o discard,defaults "$disk" "$MOUNT_DIR"
  chmod -R 777 "$MOUNT_DIR"
  
  echo "$disk $MOUNT_DIR ext4 defaults,nofail,discard 0 0" >> /etc/fstab
  echo "磁盘挂载完成"
}

setup_disk() {
  # 获取所有SCSI磁盘完整路径
  mapfile -t scsi_disks < <(find /dev/disk/by-id/ -name 'scsi-*' ! -name '*part*' -print)
  num_disks=${#scsi_disks[@]}
  
  if [ $num_disks -eq 0 ]; then
    echo "错误：未找到可用SCSI磁盘！"
    exit 1
  fi

  # 处理RAID0参数
  if $RAID0; then
    if [ $num_disks -lt 2 ]; then
      echo "错误：RAID0需要至少2块磁盘，但只找到 $num_disks 块"
      exit 1
    fi
    create_raid0 "${scsi_disks[@]}"
    return
  fi

  # 交互式选择
  if [ $num_disks -eq 1 ]; then
    mount_disk "${scsi_disks[0]}"
  else
    echo "可用的SCSI磁盘："
    for i in "${!scsi_disks[@]}"; do 
      echo "$((i+1)). ${scsi_disks[$i]}"
    done
    
    read -p "请选择 (输入磁盘编号/raid0/全路径): " choice
    case $choice in
      raid0)
        create_raid0 "${scsi_disks[@]}"
        ;;
      [1-9]*)
        if (( choice >= 1 && choice <= num_disks )); then
          mount_disk "${scsi_disks[$((choice-1))]}"
        else
          echo "无效选择！"
          exit 1
        fi
        ;;
      *)
        if [[ -b "$choice" ]]; then
          mount_disk "$choice"
        else
          echo "无效的磁盘路径！"
          exit 1
        fi
        ;;
    esac
  fi
}

setup_disk

# 安装qBittorrent
TOTAL_MEM=$(free -m | awk '/Mem/{print $2}')
install_qbittorrent() {
  bash <(wget -qO- https://raw.githubusercontent.com/cybaijie/Dedicated-Seedbox/main/Install.sh) \
    -u "$USERNAME" \
    -p "$PASSWORD" \
    -c $((TOTAL_MEM / 4)) \
    -q 4.3.9 \
    -l v1.2.20 \
    -x
}

install_qbittorrent

# 配置IPv6
configure_ipv6() {
  read -p "是否要配置IPv6？[Y/n] " -r
  [[ $REPLY =~ ^[Nn]$ ]] && return

  if [ ! -f "/etc/network/interfaces" ]; then
    echo "未找到网络配置文件！"
    return
  fi

  # 地区配置数据
  local regions=(
    "Las Vegas (LV):2605:6400:20::1"
    "New York (NY):2605:6400:10::1"
    "Luxembourg (LU):2605:6400:30::1"
    "Miami (MA):2605:6400:40::1"
  )

  # 显示地区菜单
  echo -e "\n可用地区配置："
  for i in "${!regions[@]}"; do
    IFS=":" read -r name gateway <<< "${regions[$i]}"
    printf "%-2s) %-15s 网关: %s\n" "$((i+1))" "$name" "$gateway"
  done

  # 获取用户输入
  while true; do
    read -p "请选择地区(1-4)或直接输入网关地址: " choice
    # 数字选择处理
    if [[ $choice =~ ^[1-4]$ ]]; then
      index=$((choice-1))
      IFS=":" read -r _ gateway <<< "${regions[$index]}"
      break
    # 直接输入网关处理
    elif [[ "$choice" =~ ^[0-9a-fA-F:]+$ ]]; then
      gateway="$choice"
      break
    else
      echo "错误：无效输入，请重新输入数字(1-4)或有效IPv6网关地址"
    fi
  done

  # 获取IPv6地址
  while true; do
    read -p "请输入IPv6地址: " ipv6_address
    if [[ "$ipv6_address" =~ ^[0-9a-fA-F:]+$ ]]; then
      break
    else
      echo "错误：IPv6地址格式无效"
    fi
  done

  # 写入配置文件
  echo -e "\niface eth0 inet6 static" >> /etc/network/interfaces
  echo -e "\taddress $ipv6_address" >> /etc/network/interfaces
  echo -e "\tnetmask 48" >> /etc/network/interfaces
  echo -e "\tgateway $gateway" >> /etc/network/interfaces

  echo "IPv6配置已写入/etc/network/interfaces"
  
  # 应用配置
  if systemctl restart networking >/dev/null 2>&1; then
    echo "网络服务已重新加载，当前IP配置："
    ip -6 addr show dev eth0 | awk '/inet6/{print $2}'
  else
    echo "警告：网络服务重载失败，建议手动检查配置"
  fi
}

# 执行配置
# configure_ipv6

# 统一询问重启
read -p "是否要立即重启系统？[Y/n] " -r
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
  echo "系统将在5秒后重启..."
  sleep 5
  reboot
fi

echo "所有操作已完成！"
