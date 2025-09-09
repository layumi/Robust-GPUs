import subprocess
from collections import Counter

# 需要识别的用户列表（名字 -> 用户ID）
target_users = {
    "张冀正": "yc57914",
    "张家豪": "yc57963",
    "张立天": "mc55087",
    "吴润民": "mc55429",
    "高宇成": "mc55062",
    "潭思盈": "mc55138",
    "赵瑞": "mc55268",
    "曾家瑞": "mc56750",
    "李亚轩": "yaxuanli",
    "方云松": "mc45296",
    "许伟锋": "mc56486",
    "mingyang": "mc45294",
    "ruiyang": "yc47931",
    "juhao": "yc47429",
    "zdzheng": "zhedongz",
}

def get_squeue_output():
    """运行 squeue 并返回结果（文本）"""
    result = subprocess.run(["squeue"], capture_output=True, text=True)
    return result.stdout

def parse_squeue_for_users(output, target_users):
    """解析 squeue 输出，返回在队列中的目标用户计数"""
    counter = Counter()
    lines = output.strip().split("\n")

    # 跳过表头，从第二行开始
    for line in lines[1:]:
        parts = line.split()
        if len(parts) >= 4:  # USER 一般在第4列
            user = parts[3]
            for name, uid in target_users.items():
                if user == uid:
                    counter[(name, uid)] += 1
    return counter

if __name__ == "__main__":
    output = get_squeue_output()
    counter = parse_squeue_for_users(output, target_users)

    if counter:
        print("在队列中的目标用户及任务数：")
        for (name, uid), count in counter.items():
            print(f"{name}\t{uid}\t{count} 个任务")
    else:
        print("没有找到目标用户。")
