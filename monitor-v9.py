from gevent import monkey
monkey.patch_all()

import gevent
import paramiko
from flask import Flask
from datetime import datetime
import json
import logging
from collections import Counter, defaultdict
import time

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# ====================== 配置 ======================
machines = ['10.119.46.58', '10.119.46.59', '10.119.178.21', '10.119.44.40', '10.119.46.65', '10.119.46.67', '10.119.183.78']
machine_name = ['um1', 'um2', 'um3', 'um4', 'um5', 'um7', 'jizheng']
machine_map = dict(zip(machines, machine_name))

cluster_host = '10.119.48.10'
username = 'metagpu'

# 你最新的 target_users
target_users = {
    "jizheng": "yc57914",
    "jiahao": "yc57963",
    "litian": "mc55087",
    "runmin": "mc55429",
    "yuchen": "mc55062",
    "siying": "mc55138",
    "zhaorui": "mc55268",
    "jiarui": "mc56750",
    "yaxuan": "yaxuanli",
    "yunsong": "mc45296",
    "weifeng": "mc56486",
    "mingyang": "mc45294",
    "ruiyang": "yc47931",
    "juhao": "yc47429",
    "zdzheng": "zhedongz",
    "feihong": "yc58103",
    "chenxu": "chenxu",
    "linzeju": "linzeju",
}

ignore_users = {'root', 'admuser', 'ollama', 'user', 'nobody', 'daemon'}

GPU_CACHE_DURATION = 180
CLUSTER_CACHE_DURATION = 1800

cache = {}
cluster_cache = {}

# 排行榜
gpu_usage_log = defaultdict(float)
last_usage_update = time.time()


# ====================== 函数 ======================
def get_gpu_status(host):
    logger.debug(f"Attempting to get GPU status for host: {host}")
    if host not in machines:
        return f"Error: Invalid host {host}"

    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(host, username=username, timeout=10)

        command = '/home/metagpu/miniconda3/bin/gpustat --json'
        stdin, stdout, stderr = client.exec_command(command)
        output = stdout.read().decode().strip()
        error = stderr.read().decode().strip()
        client.close()

        if error:
            logger.error(f"Command error on {host}: {error}")
            return f"Command error: {error}"

        gpu_data = json.loads(output)
        return gpu_data.get('gpus', [])

    except Exception as e:
        logger.error(f"Failed to get GPU status from {host}: {str(e)}")
        return f"Connection failed: {str(e)}"


def get_squeue_output():
    logger.debug(f"Running squeue on {cluster_host}")
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(cluster_host, username='zhedongzheng', timeout=10)

        stdin, stdout, stderr = client.exec_command(
            '/home/user/zhedongzheng/miniconda3/bin/python check_squeue_users.py'
        )
        output = stdout.read().decode().strip()
        error = stderr.read().decode().strip()
        client.close()

        if error:
            logger.error(f"squeue command error: {error}")
            return None, f"Command error: {error}"

        return output, None

    except Exception as e:
        logger.error(f"Connection failed for squeue: {str(e)}")
        return None, f"Connection failed: {str(e)}"


def parse_squeue_for_users(output, target_users):
    counter = Counter()
    if not output:
        return counter
    lines = output.strip().split("\n")
    for line in lines[1:]:
        parts = line.split()
        if len(parts) >= 3:
            user = parts[1]
            for name, uid in target_users.items():
                if user == uid:
                    counter[(name, uid)] = int(parts[2])
    return counter


def get_squeue_status():
    output, error = get_squeue_output()
    if error:
        return error

    counter = parse_squeue_for_users(output, target_users)
    total_jobs = sum(counter.values())
    per_user = {uid: count for (name, uid), count in counter.items()}
    return {'total': total_jobs, 'per_user': per_user}


def get_cached_gpu_status(machine):
    """仅获取GPU状态和缓存"""
    cached = cache.get(machine)
    current_time = datetime.now()

    if cached and (current_time - cached['timestamp']).total_seconds() < GPU_CACHE_DURATION:
        return cached['data']

    gpu_data = get_gpu_status(machine)
    cache[machine] = {'data': gpu_data, 'timestamp': current_time}
    return gpu_data


def get_cached_squeue_status():
    cached = cluster_cache.get('cluster')
    current_time = datetime.now()

    if cached and (current_time - cached['timestamp']).total_seconds() < CLUSTER_CACHE_DURATION:
        return cached['data']

    job_data = get_squeue_status()
    cluster_cache['cluster'] = {'data': job_data, 'timestamp': current_time}
    return job_data


def update_gpu_usage_log(status):
    """每3分钟统计一次排行榜"""
    global gpu_usage_log
    temp_log = defaultdict(float)

    for machine, gpus in status.items():
        if isinstance(gpus, str) or not isinstance(gpus, list):
            continue
        for gpu in gpus:
            if not isinstance(gpu, dict):
                continue
            processes = gpu.get('processes', [])
            util = gpu.get('utilization.gpu', 0)
            if not isinstance(util, (int, float)) or util <= 5:
                continue

            for p in processes:
                username = p.get('username')
                if not username or username in ignore_users:
                    continue
                for name, uid in target_users.items():
                    if username == uid or username.lower() == name.lower():
                        temp_log[name] += (1.0 / 60) * (util / 100.0)
                        break

    for name, hours in temp_log.items():
        gpu_usage_log[name] += hours

    logger.info(f"排行榜更新完成，本次统计用户数: {len(temp_log)}")


def get_utilization_color(utilization):
    try:
        util = int(utilization)
        if util <= 30: return 'green'
        elif util <= 70: return 'yellow'
        else: return 'red'
    except:
        return 'white'


def get_memory_color(mem_used, mem_total):
    try:
        used = int(mem_used)
        total = int(mem_total)
        percent = (used / total) * 100
        if percent <= 30: return 'green'
        elif percent <= 70: return 'yellow'
        else: return 'red'
    except:
        return 'white'


# ====================== 主页面 ======================
@app.route('/')
def monitor():
    # GEVENT 并行获取数据
    gpu_jobs = {machine: gevent.spawn(get_cached_gpu_status, machine) for machine in machines}
    squeue_job = gevent.spawn(get_cached_squeue_status)
    gevent.joinall(list(gpu_jobs.values()) + [squeue_job])

    # 收集 GPU 状态
    status = {}
    for machine, job in gpu_jobs.items():
        try:
            status[machine] = job.value if job.successful() else f"Error: {job.exception}"
        except Exception as e:
            status[machine] = f"Error: {e}"

    # 每3分钟更新一次排行榜
    global last_usage_update
    if time.time() - last_usage_update > 180:   # 180秒 = 3分钟
        logger.info("触发排行榜统计（每3分钟一次）")
        update_gpu_usage_log(status)
        last_usage_update = time.time()

    # 收集 squeue 状态
    try:
        squeue_status = squeue_job.value if squeue_job.successful() else f"Error: {squeue_job.exception}"
    except Exception as e:
        squeue_status = f"Error: {e}"

    # ====================== HTML 开始 ======================
    sorted_ranking = sorted(gpu_usage_log.items(), key=lambda x: x[1], reverse=True)[:10]

    html = f"""
    <!DOCTYPE html>
    <html lang="zh">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>GPU Status Monitor</title>
        <style>
            body {{ font-family: 'Courier New', Courier, monospace; background-color: #000000; color: #ffffff; margin: 20px; line-height: 1.4; }}
            table {{ border-collapse: collapse; width: 100%; margin-bottom: 25px; background-color: #1a1a1a; table-layout: fixed; }}
            th, td {{ border: 1px solid #444444; padding: 8px 10px; text-align: left; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }}
            th {{ background-color: #333333; }}
            .machine-header {{ background-color: #2a2a2a; padding: 12px 10px; margin-top: 15px; font-weight: bold; font-size: 1.1em; }}
            .error {{ color: #ff5555; }}
            .util-green {{ color: #00ff00; }} 
            .util-yellow {{ color: #ffff00; }} 
            .util-red {{ color: #ff0000; }}
            .ranking {{ background:#2a2a2a; padding:15px; border-radius:8px; margin-bottom:25px; }}
            .col-index {{ width: 70px; }}
            .col-name  {{ width: 430px; }}
            .col-util  {{ width: 120px; }}
            .col-mem   {{ width: 170px; }}
            .col-proc  {{ width: auto; min-width: 200px; }}
        </style>
    </head>
    <body>
        <h1>GPU 集群实时监控</h1>

        <!-- 排行榜 -->
        <div class="ranking">
            <h2>🏆 本周 GPU 使用英雄榜（Top 10）</h2>
            <table>
                <thead>
                    <tr>
                        <th style="width:50px;">排名</th>
                        <th>用户</th>
                        <th style="width:150px;">使用时长 (GPU·h)</th>
                        <th style="width:110px;">贡献值</th>
                    </tr>
                </thead>
                <tbody>
    """

    for rank, (name, hours) in enumerate(sorted_ranking, 1):
        contrib = round(hours * 0.85, 1)
        html += f'                    <tr><td>{rank}</td><td>{name}</td><td>{hours:.1f}</td><td>{contrib} ★</td></tr>'

    if not sorted_ranking:
        html += '<tr><td colspan="4" style="text-align:center;">暂无使用记录</td></tr>'

    html += """
                </tbody>
            </table>
            <small style="color:#888;">每 3 分钟自动更新 · 只统计真实用户</small>
        </div>
    """

    # GPU 机器状态表格
    for machine in machines:
        machine_display_name = machine_map.get(machine, machine)
        gpus = status.get(machine)

        html += f'<div class="machine-header">Machine: {machine_display_name} ({machine})</div>'

        if isinstance(gpus, str):
            html += f'<p class="error">{gpus}</p>'
        else:
            html += """
            <table>
                <thead>
                    <tr>
                        <th class="col-index">GPU Index</th>
                        <th class="col-name">GPU Name</th>
                        <th class="col-util">Utilization (%)</th>
                        <th class="col-mem">Memory Used/Total (MiB)</th>
                        <th class="col-proc">Processes</th>
                    </tr>
                </thead>
                <tbody>
            """
            for gpu in (gpus if isinstance(gpus, list) else []):
                index = gpu.get('index', 'N/A')
                name_gpu = gpu.get('name', 'N/A')
                utilization = gpu.get('utilization.gpu', 'N/A')
                mem_used = gpu.get('memory.used', 'N/A')
                mem_total = gpu.get('memory.total', 'N/A')
                proc_list = gpu.get('processes', [])
                proc_str = ', '.join([f"{p.get('username')}:{p.get('pid')}" 
                                    for p in proc_list if p.get('username') not in ignore_users]) or 'None'

                util_color = get_utilization_color(utilization)
                mem_color = get_memory_color(mem_used, mem_total)

                html += f"""
                <tr>
                    <td class="col-index">{index}</td>
                    <td class="col-name" title="{name_gpu}">{name_gpu}</td>
                    <td class="col-util util-{util_color}">{utilization}</td>
                    <td class="col-mem util-{mem_color}">{mem_used}/{mem_total}</td>
                    <td class="col-proc">{proc_str}</td>
                </tr>
                """
            html += '</tbody></table>'

    # ================== 你原来的 Cluster 部分（完整保留） ==================
    html += '<div class="cluster-info" style="margin-top:30px; padding:15px; background-color:#2a2a2a;">'
    html += '<h2> 1. 国重 SICC Cluster (dgx.sicc.um.edu.mo)</h2>'
    html += f'<p> SICC User Manual: http://services.sicc.um.edu.mo:8443/sicc_admin/GPU/src/branch/master/DGX-Cluster </p>'
    
    html += '<h2> 2. 学院 FST Cluster Job Queue (10.119.48.10)</h2>'

    if isinstance(squeue_status, str):
        html += f'<p class="error">{squeue_status}</p>'
    else:
        total_jobs = squeue_status.get('total', 0)
        per_user = squeue_status.get('per_user', {})
        user_jobs = [f"{name} ({userid}): {per_user.get(userid, 0)}" 
                     for name, userid in target_users.items() if per_user.get(userid, 0) > 0]
        user_jobs_str = ", ".join(user_jobs) if user_jobs else "None"
        html += f'<p>Total jobs: {total_jobs} ({user_jobs_str})</p>'

    html += """
    <h3>FST Cluster Information</h3>
    <table>
        <thead>
            <tr>
                <th>Partition Name</th>
                <th>Number of GPU in total</th>
                <th>GPU</th>
                <th>Time limit</th>
                <th>Partition QOS</th>
                <th>QOS</th>
            </tr>
        </thead>
        <tbody>
            <tr>
                <td>gbunchQ</td>
                <td>12</td>
                <td>A40 48GB PCIE</td>
                <td>3 days</td>
                <td>4 GPUs pre user simultaneously</td>
                <td>- Each PI group can occupy maximum 6 GPUs simultaneously<br>- Each user can occupy maximum 4 GPUs simultaneously<br>- Each user can only run 2 jobs, and submit 4 jobs simultaneously</td>
            </tr>
            <tr>
                <td>gbunchQ1</td>
                <td>3</td>
                <td>3090 x2 (fstsvr03)<br>V100 x1 (fstsvr02)</td>
                <td>7 days</td>
                <td>4 GPUs pre user simultaneously</td>
                <td></td>
            </tr>
            <tr>
                <td>gbunchQ2</td>
                <td>12</td>
                <td>A100 80GB PCIE</td>
                <td>2 days</td>
                <td>4 GPUs pre user simultaneously</td>
                <td></td>
            </tr>
            <tr>
                <td>gbunchQ3</td>
                <td>2</td>
                <td>H800 80GB PCIE</td>
                <td>2 days</td>
                <td>1 GPU pre user simultaneously</td>
                <td></td>
            </tr>
        </tbody>
    </table>
    </div>
    </body>
    </html>
    """

    return html


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
