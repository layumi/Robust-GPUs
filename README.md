Code contains risk!

### Change GPU Power
```
sudo nvidia-smi -pm 1 # enable persistance mode
sudo nvidia-smi -pl 200  # set to 200W
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
