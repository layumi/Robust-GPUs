Code contains risk!

### Change GPU Power
```
nvidia-smi -pm 1 # enable persistance mode
nvidia-smi -pl 200  # set to 200W
```

### Change Fan


```
nvidia-settings -a "[gpu:0]/GPUFanControlState=1"
nvidia-settings -a "[fan:0]/GPUTargetFanSpeed=100"
```

https://ubuntuforums.org/showthread.php?t=2380735
```
cd /etc/X11
sudo nvidia-xconfig --enable-all-gpus
nvidia-xconfig --cool-bits=4
```

### Related Repos & Blogs

- https://github.com/boris-dimitrov/set_gpu_fans_public

- https://tutorials.technology/tutorials/86-How-to-adjust-NVIDIA-GPU-power-usage-on-linux.html
