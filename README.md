Code contains risk!

https://www.techticity.com/howto/how-to-control-nvidia-graphics-card-fan-speed-in-linux/ 

### enlarge swap with 32GB
```
sudo fallocate -l 32G /swapfile1
sudo chmod 600 /swapfile1
sudo mkswap /swapfile1
sudo swapon /swapfile1
```

### set memory limits for every user
```
sudo bash ./set_memlimit.sh 60G
```

### tmux setting 
```bash
echo "set -g history-limit 5000" >> ~/.tmux.conf
```

### bash setting
```
# set PATH for cuda 12.2 installation
export PATH=/usr/local/cuda-12.2/bin${PATH:+:${PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda-12.2/includei:/usr/include/:${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
export LD_LIBRARY_PATH=/usr/local/cuda-12.2/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}
export CUDA_PATH=/usr/local/cuda-12.2
export CUDA_ROOT=/usr/local/cuda-12.2
export CUDA_HOME=/usr/local/cuda-12.2
export CUDA_HOST_COMPILER=/usr/bin/gcc
```

https://askubuntu.com/questions/1340946/nvidia-rtx-3070-eth-overclock-in-ubuntu20-04-nvidia-settings-a-gpugraphicscloc 
### GPU Clock
```
sudo DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 nvidia-settings -a '[gpu:1]/GPUMemoryTransferRateOffsetAllPerformanceLevels=500'
sudo DISPLAY=:0 XAUTHORITY=/var/run/lightdm/root/:0 nvidia-settings -a '[gpu:1]/GPUGraphicsClockOffsetAllPerformanceLevels=200'
```


### CPU Memory Control
160GB limited.
```
 ulimit -m 160000000
```

### FAN control 
```
sudo nvidia-xconfig -a --cool-bits=28 --allow-empty-initial-configuration
```

### Change GPU Power
```
sudo nvidia-smi -pm 1 # enable persistance mode
sudo nvidia-smi -pl 200  # set to 200W
```

### Auto-boost clock 
```
sudo nvidia-smi --auto-boost-default=ENABLED -i 0
```

If you want to retain this setting, you may add these two lines to `etc/rc.local`
### Change Fan


```
nvidia-settings -a "[gpu:0]/GPUFanControlState=1"
nvidia-settings -a "[fan:0]/GPUTargetFanSpeed=100"
```

https://ubuntuforums.org/showthread.php?t=2380735
```
cd /etc/X11
sudo nvidia-xconfig --enable-all-gpus
sudo nvidia-xconfig --cool-bits=12
```
https://wiki.archlinux.org/index.php/NVIDIA/Tips_and_tricks#Set_fan_speed_at_login


### Related Repos & Blogs

- https://github.com/boris-dimitrov/set_gpu_fans_public

- https://tutorials.technology/tutorials/86-How-to-adjust-NVIDIA-GPU-power-usage-on-linux.html


### Vim Color 
```
echo "hi comment ctermbg=4 ctermfg=6" >> ~/.vimrc
```
