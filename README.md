Code contains risk!

https://www.techticity.com/howto/how-to-control-nvidia-graphics-card-fan-speed-in-linux/ 
### FAN controal 
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
