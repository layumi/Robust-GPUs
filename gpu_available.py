import os

os.system('cnode >tmp.txt')
with open('tmp.txt','r') as f:
    for i in range(10):
        for line in f:
            break
    for line in f:
        line = line.replace('\n','')
        line = " ".join(line.split())
        cell = line.split(' ')
        if len(cell)!=8:
            continue
        name = cell[0]
        ava = cell[2]
        if 'no'in ava:
            continue
        if name[0] == 'o' or name[0] == 'a':
            continue
        gpu_memory = cell[6]
        if float(gpu_memory)>50:
            continue
        print(name)
