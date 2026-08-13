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
machines = ['10.119.46.58', '10.119.46.59', '10.119.178.21', '10.119.44.40', '10.119.46.65', '10.119.46.67']
machine_name = ['um1', 'um2', 'um3', 'um4', 'um5', 'um7']
machine_map = dict(zip(machines, machine_name))
cluster_host = '10.119.48.10'
username = 'metagpu'

target_users = {
    "jizheng": "yc57914",
    "jiahao": "yc57963",
    "litian": "mc55087",
    "yuchen": "mc55062",
    "siying": "mc55138",
    "zhaorui": "mc55268",
    "jiarui": "mc56750",
    "yaxuan": "yaxuanli",
    "yunsong": "mc45296",
    "weifeng": "mc56486",
    "mingyang": "yc67382",
    "ruiyang": "yc47931",
    "juhao": "yc47429",
    "zdzheng": "zhedongz",
    "feihong": "yc58103",
    "chenxu": "yc67196",
    "linzeju": "yc67203",
    "xiji": "mc64693",
}
ignore_users = {'root', 'admuser', 'ollama', 'user', 'nobody', 'daemon'}

GPU_CACHE_DURATION = 180
CLUSTER_CACHE_DURATION = 1800
cache = {}
cluster_cache = {}
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
    gpu_jobs = {machine: gevent.spawn(get_cached_gpu_status, machine) for machine in machines}
    squeue_job = gevent.spawn(get_cached_squeue_status)
    gevent.joinall(list(gpu_jobs.values()) + [squeue_job])

    status = {}
    for machine, job in gpu_jobs.items():
        try:
            status[machine] = job.value if job.successful() else f"Error: {job.exception}"
        except Exception as e:
            status[machine] = f"Error: {e}"

    global last_usage_update
    if time.time() - last_usage_update > 180:
        logger.info("触发排行榜统计（每3分钟一次）")
        update_gpu_usage_log(status)
        last_usage_update = time.time()

    try:
        squeue_status = squeue_job.value if squeue_job.successful() else f"Error: {squeue_job.exception}"
    except Exception as e:
        squeue_status = f"Error: {e}"

    sorted_ranking = sorted(gpu_usage_log.items(), key=lambda x: x[1], reverse=True)[:10]

    # 计算当前空闲 GPU 数量（简单统计）
    free_gpu_count = 0
    total_gpu_count = 0
    for machine, gpus in status.items():
        if isinstance(gpus, list):
            for gpu in gpus:
                total_gpu_count += 1
                util = gpu.get('utilization.gpu', 100)
                mem_used = gpu.get('memory.used', 99999)
                if (isinstance(util, (int, float)) and util < 10) and (isinstance(mem_used, (int, float)) and mem_used < 500):
                    free_gpu_count += 1

    html = f"""
<!DOCTYPE html>
<html lang="zh">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>GPU 集群监控 · AIGC-DL Lab</title>
    <style>
        :root {{
            --bg: #0f1115;
            --card: #1a1d24;
            --border: #2d323c;
            --text: #e6e8ec;
            --muted: #9aa3b2;
            --green: #22c55e;
            --yellow: #eab308;
            --red: #ef4444;
            --blue: #3b82f6;
            --purple: #a855f7;
        }}
        * {{ box-sizing: border-box; }}
        body {{
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            background: var(--bg);
            color: var(--text);
            margin: 0;
            padding: 20px;
            line-height: 1.5;
        }}
        h1 {{ margin: 0 0 8px; font-size: 1.8rem; }}
        h2 {{ margin: 0 0 12px; font-size: 1.25rem; }}
        h3 {{ margin: 16px 0 8px; font-size: 1.05rem; color: #cbd5e1; }}
        .banner {{
            background: linear-gradient(90deg, #1e3a5f, #312e81);
            border: 1px solid #3b82f6;
            border-radius: 12px;
            padding: 16px 20px;
            margin: 16px 0 24px;
            font-size: 1.05rem;
            line-height: 1.6;
        }}
        .banner strong {{ color: #93c5fd; }}
        .stats-row {{
            display: flex;
            gap: 16px;
            margin-bottom: 24px;
            flex-wrap: wrap;
        }}
        .stat-card {{
            background: var(--card);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 16px 20px;
            min-width: 160px;
            flex: 1;
        }}
        .stat-card .label {{ color: var(--muted); font-size: 0.85rem; }}
        .stat-card .value {{ font-size: 1.6rem; font-weight: 700; margin-top: 4px; }}
        .ranking {{
            background: var(--card);
            border: 1px solid var(--border);
            border-radius: 12px;
            padding: 20px;
            margin-bottom: 28px;
        }}
        table {{
            border-collapse: collapse;
            width: 100%;
            background: #16191f;
            border-radius: 8px;
            overflow: hidden;
        }}
        th, td {{
            border: 1px solid var(--border);
            padding: 10px 12px;
            text-align: left;
        }}
        th {{ background: #22262e; color: #cbd5e1; font-weight: 600; }}
        .machine-header {{
            background: #22262e;
            padding: 12px 16px;
            margin-top: 20px;
            border-radius: 8px 8px 0 0;
            font-weight: 600;
            font-size: 1.05rem;
            border: 1px solid var(--border);
            border-bottom: none;
        }}
        .error {{ color: var(--red); }}
        .util-green {{ color: var(--green); }}
        .util-yellow {{ color: var(--yellow); }}
        .util-red {{ color: var(--red); }}
        .medal {{ font-size: 1.15rem; }}
        .cluster-box {{
            background: linear-gradient(145deg, #1a2332, #1e1b2e);
            border: 1px solid #3b82f6;
            border-radius: 12px;
            padding: 20px;
            margin-top: 32px;
        }}
        .tip {{
            background: #1e293b;
            border-left: 4px solid #3b82f6;
            padding: 12px 16px;
            margin: 12px 0;
            border-radius: 0 8px 8px 0;
            font-size: 0.95rem;
        }}
        code {{
            background: #0f172a;
            padding: 2px 6px;
            border-radius: 4px;
            font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
            font-size: 0.9em;
        }}
        .footer-note {{
            color: var(--muted);
            font-size: 0.85rem;
            margin-top: 12px;
        }}
        .col-index {{ width: 80px; }}
        .col-name {{ width: 280px; }}
        .col-util {{ width: 120px; }}
        .col-mem {{ width: 180px; }}
        .col-proc {{ width: auto; }}
    </style>
</head>
<body>
    <h1>GPU 集群实时监控 · AIGC-DL Lab</h1>

    <!-- 鼓励使用 Cluster 的横幅 -->
    <div class="banner">
        🚀 <strong>本地 GPU 资源有限，强烈推荐大家多用 Cluster！</strong><br>
        FST Cluster 有 A40 / A100 / H800，SICC 有更多 DGX 资源。<br>
        本地机器适合调试，正式训练请提交到 Cluster，既快又稳定，还能积累更多使用时长！
    </div>

    <!-- 快速概览 -->
    <div class="stats-row">
        <div class="stat-card">
            <div class="label">本地机器空闲 GPU</div>
            <div class="value" style="color: var(--green);">{free_gpu_count} / {total_gpu_count}</div>
        </div>
        <div class="stat-card">
            <div class="label">FST Cluster 当前作业</div>
            <div class="value" style="color: var(--blue);">
                {squeue_status.get('total', 0) if isinstance(squeue_status, dict) else '—'}
            </div>
        </div>
        <div class="stat-card">
            <div class="label">本周统计用户</div>
            <div class="value">{len(gpu_usage_log)}</div>
        </div>
    </div>

    <!-- 排行榜 -->
    <div class="ranking">
        <h2>🏆 本周 GPU 使用英雄榜（Top 10）</h2>
        <p style="color: var(--muted); margin: 0 0 16px; font-size: 0.95rem;">
            本地调试 + Cluster 正式训练都算贡献。多用 Cluster，榜上有名更快！
        </p>
        <table>
            <thead>
                <tr>
                    <th style="width:70px;">排名</th>
                    <th>用户</th>
                    <th style="width:140px;">使用时长 (GPU·h)</th>
                    <th style="width:120px;">贡献值</th>
                    <th style="width:100px;">等级</th>
                </tr>
            </thead>
            <tbody>
"""

    medals = ['🥇', '🥈', '🥉']
    for rank, (name, hours) in enumerate(sorted_ranking, 1):
        contrib = round(hours * 0.85, 1)
        medal = medals[rank-1] if rank <= 3 else f"{rank}"
        if hours >= 50:
            level = "🔥 大神"
        elif hours >= 20:
            level = "⭐ 主力"
        elif hours >= 5:
            level = "💪 活跃"
        else:
            level = "🌱 新人"
        html += f'''
                <tr>
                    <td class="medal">{medal}</td>
                    <td><strong>{name}</strong></td>
                    <td>{hours:.1f}</td>
                    <td>{contrib} ★</td>
                    <td>{level}</td>
                </tr>'''

    if not sorted_ranking:
        html += '<tr><td colspan="5" style="text-align:center; color:#9aa3b2;">暂无使用记录，快去跑起来！</td></tr>'

    html += """
            </tbody>
        </table>
        <div class="footer-note">每 3 分钟自动更新 · 只统计真实用户 · 本地 + Cluster 使用都会被鼓励</div>
    </div>
"""

    # 本地机器状态
    for machine in machines:
        machine_display_name = machine_map.get(machine, machine)
        gpus = status.get(machine)
        html += f'<div class="machine-header">🖥️  Machine: {machine_display_name} ({machine})</div>'
        if isinstance(gpus, str):
            html += f'<p class="error" style="padding:12px;">{gpus}</p>'
        else:
            html += """
            <table>
                <thead>
                    <tr>
                        <th class="col-index">GPU</th>
                        <th class="col-name">型号</th>
                        <th class="col-util">利用率</th>
                        <th class="col-mem">显存 (MiB)</th>
                        <th class="col-proc">进程</th>
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
                    <td class="col-util util-{util_color}">{utilization}%</td>
                    <td class="col-mem util-{mem_color}">{mem_used} / {mem_total}</td>
                    <td class="col-proc">{proc_str}</td>
                </tr>
                """
            html += '</tbody></table>'

    # ================== Cluster 区域（重点鼓励） ==================
    html += """
    <div class="cluster-box">
        <h2>🚀 强烈推荐：使用 Cluster 资源</h2>
        
        <div class="tip">
            <strong>为什么推荐用 Cluster？</strong><br>
            • 本地机器 GPU 数量有限，容易互相抢资源<br>
            • Cluster 有 A40 / A100 80GB / H800，显存更大、更快<br>
            • 正式实验请提交到 Cluster，本地只做调试和小规模验证<br>
            • 多用 Cluster 也算进英雄榜贡献，一起冲榜！
        </div>

        <h3>1. 国重 SICC Cluster (dgx.sicc.um.edu.mo)</h3>
        <p>SICC 用户手册：
            <a href="http://services.sicc.um.edu.mo:8443/sicc_admin/GPU/src/branch/master/DGX-Cluster" 
               style="color:#93c5fd;" target="_blank">
               http://services.sicc.um.edu.mo:8443/sicc_admin/GPU/src/branch/master/DGX-Cluster
            </a>
        </p>

        <h3>2. 学院 FST Cluster Job Queue (10.119.48.10)</h3>
"""

    if isinstance(squeue_status, str):
        html += f'<p class="error">{squeue_status}</p>'
    else:
        total_jobs = squeue_status.get('total', 0)
        per_user = squeue_status.get('per_user', {})
        user_jobs = [f"<strong>{name}</strong> ({userid}): {per_user.get(userid, 0)}"
                     for name, userid in target_users.items() if per_user.get(userid, 0) > 0]
        user_jobs_str = " · ".join(user_jobs) if user_jobs else "当前无作业"
        html += f'<p>当前总作业数：<strong style="color:#3b82f6; font-size:1.2rem;">{total_jobs}</strong></p>'
        html += f'<p>组内用户作业分布：{user_jobs_str}</p>'

    html += """
        <h3>FST Cluster 分区信息</h3>
        <table>
            <thead>
                <tr>
                    <th>Partition</th>
                    <th>GPU 总数</th>
                    <th>GPU 型号</th>
                    <th>时间限制</th>
                    <th>主要限制</th>
                </tr>
            </thead>
            <tbody>
                <tr>
                    <td><code>gbunchQ</code></td>
                    <td>12</td>
                    <td>A40 48GB</td>
                    <td>3 天</td>
                    <td>每用户最多 4 卡，每组最多 6 卡</td>
                </tr>
                <tr>
                    <td><code>gbunchQ1</code></td>
                    <td>3</td>
                    <td>3090 ×2 + V100 ×1</td>
                    <td>7 天</td>
                    <td>每用户最多 4 卡</td>
                </tr>
                <tr>
                    <td><code>gbunchQ2</code></td>
                    <td>12</td>
                    <td>A100 80GB</td>
                    <td>2 天</td>
                    <td>每用户最多 4 卡</td>
                </tr>
                <tr>
                    <td><code>gbunchQ3</code></td>
                    <td>2</td>
                    <td>H800 80GB</td>
                    <td>2 天</td>
                    <td>每用户最多 1 卡</td>
                </tr>
            </tbody>
        </table>

        <div class="tip" style="margin-top:20px;">
            <strong>快速提交示例（sbatch）：</strong><br>
            <code>#!/bin/bash<br>
#SBATCH --partition=gbunchQ2<br>
#SBATCH --gres=gpu:1<br>
#SBATCH --time=1-00:00:00<br>
#SBATCH --job-name=my_exp<br>
python train.py</code>
        </div>
    </div>

    <div style="text-align:center; color:#64748b; margin:40px 0 20px; font-size:0.9rem;">
        AIGC-DL Lab · University of Macau · 本地调试 + Cluster 正式训练，一起把实验跑起来 💪
    </div>
</body>
</html>
"""
    return html

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
