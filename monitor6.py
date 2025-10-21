from gevent import monkey
monkey.patch_all()
import paramiko
from flask import Flask
from datetime import datetime, timedelta
import json
from collections import Counter
import logging

# Set up logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Machine IPs and corresponding names
machines = ['10.119.46.58', '10.119.46.59', '10.119.178.21', '10.119.46.65']
machine_name = ['um1', 'um2', 'um3', 'um5']
machine_map = dict(zip(machines, machine_name))

# Cluster for squeue
cluster_host = '10.119.48.10'

# SSH credentials (replace with your actual password or use SSH keys)
username = 'metagpu'

# Target users for squeue (removed zhedongz due to invalid user error)
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

# Cache settings
GPU_CACHE_DURATION = 180  # 180 seconds for GPU status
CLUSTER_CACHE_DURATION = 1800  # 30 minutes for cluster jobs
cache = {}  # {machine_ip: {'data': gpu_data, 'timestamp': datetime}}
cluster_cache = {}  # {'cluster': {'data': job_data, 'timestamp': datetime}}

def get_gpu_status(host):
    logger.debug(f"Attempting to get GPU status for host: {host}")
    if host not in machines:
        logger.error(f"Invalid host: {host}")
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
        
        try:
            gpu_data = json.loads(output)
            return gpu_data.get('gpus', [])
        except json.JSONDecodeError as e:
            logger.error(f"JSON parsing error on {host}: {str(e)}")
            return f"JSON parsing error: {str(e)}"
    
    except paramiko.AuthenticationException:
        logger.error(f"Authentication failed for {host}")
        return f"Authentication failed for {host}"
    except paramiko.SSHException as e:
        logger.error(f"SSH error for {host}: {str(e)}")
        return f"SSH error: {str(e)}"
    except TimeoutError:
        logger.error(f"Connection timeout to {host}")
        return f"Connection timeout to {host}"
    except Exception as e:
        logger.error(f"Connection failed for {host}: {str(e)}")
        return f"Connection failed: {str(e)}"

def get_squeue_output():
    """Run squeue on cluster via SSH and return output."""
    logger.debug(f"Running squeue on {cluster_host}")
    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(cluster_host, username='zhedongzheng', timeout=10)
        
        stdin, stdout, stderr = client.exec_command('/home/user/zhedongzheng/miniconda3/bin/python check_squeue_users.py')
        output = stdout.read().decode().strip()
        error = stderr.read().decode().strip()
        
        client.close()
        
        if error:
            logger.error(f"squeue command error: {error}")
            return None, f"Command error: {error}"
        
        return output, None
    
    except paramiko.AuthenticationException:
        logger.error(f"Authentication failed for {cluster_host}")
        return None, f"Authentication failed for {cluster_host}"
    except paramiko.SSHException as e:
        logger.error(f"SSH error for {cluster_host}: {str(e)}")
        return None, f"SSH error: {str(e)}"
    except TimeoutError:
        logger.error(f"Connection timeout to {cluster_host}")
        return None, f"Connection timeout to {cluster_host}"
    except Exception as e:
        logger.error(f"Connection failed for {cluster_host}: {str(e)}")
        return None, f"Connection failed: {str(e)}"

def parse_squeue_for_users(output, target_users):
    """Parse squeue output and return job counts for target users."""
    counter = Counter()
    if not output:
        return counter

    lines = output.strip().split("\n")
    for line in lines[1:]:  # Skip header
        parts = line.split()
        if len(parts) >= 3:  # USER in 2nd column
            user = parts[1]
            for name, uid in target_users.items():
                if user == uid:
                    counter[(name, uid)] = int(parts[2]) # num in 3rd column
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

def get_utilization_color(utilization):
    try:
        util = int(utilization)
        if util <= 30:
            return 'green'
        elif util <= 70:
            return 'yellow'
        else:
            return 'red'
    except (ValueError, TypeError):
        return 'white'

def get_memory_color(mem_used, mem_total):
    try:
        used = int(mem_used)
        total = int(mem_total)
        usage_percent = (used / total) * 100
        if usage_percent <= 30:
            return 'green'
        elif usage_percent <= 70:
            return 'yellow'
        else:
            return 'red'
    except (ValueError, TypeError, ZeroDivisionError):
        return 'white'

@app.route('/')
def monitor():
    # Get GPU status for machines
    status = {}
    for machine in machines:
        logger.debug(f"Processing machine: {machine}")
        status[machine] = get_cached_gpu_status(machine)
    
    # Get squeue status for cluster
    squeue_status = get_cached_squeue_status()
    
    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>GPU Status Monitor</title>
        <style>
            body {{ 
                font-family: 'Courier New', Courier, monospace; 
                background-color: #000000; 
                color: #ffffff; 
                margin: 20px; 
            }}
            table {{ 
                border-collapse: collapse; 
                width: 100%; 
                margin-bottom: 20px; 
                background-color: #1a1a1a; 
            }}
            th, td {{ 
                border: 1px solid #444444; 
                padding: 8px; 
                text-align: left; 
            }}
            th {{ 
                background-color: #333333; 
                color: #ffffff; 
            }}
            .machine-header {{ 
                background-color: #2a2a2a; 
                color: #ffffff; 
                font-weight: bold; 
                padding: 10px; 
            }}
            .error {{ color: #ff5555; }}
            .util-green {{ color: #00ff00; }}
            .util-yellow {{ color: #ffff00; }}
            .util-red {{ color: #ff0000; }}
            .cluster-info {{ margin-top: 30px; padding: 10px; background-color: #2a2a2a; }}
        </style>
    </head>
    <body>
        <h1>GPU Status Across Machines</h1>
        <p>Refresh the page to update status. GPU data cached for {} seconds, cluster job data cached for {} minutes.</p>
    """.format(GPU_CACHE_DURATION, CLUSTER_CACHE_DURATION // 60)
    
    for machine in machines:
        machine_display_name = machine_map.get(machine, machine)
        gpus = status[machine]
        html += f'<div class="machine-header">Machine: {machine_display_name} ({machine})</div>'
        if isinstance(gpus, str):
            html += f'<p class="error">{gpus}</p>'
        else:
            html += """
            <table>
                <tr>
                    <th>GPU Index</th>
                    <th>GPU Name</th>
                    <th>Utilization (%)</th>
                    <th>Memory Used/Total (MiB)</th>
                    <th>Processes</th>
                </tr>
            """
            for gpu in gpus:
                index = gpu.get('index', 'N/A')
                name = gpu.get('name', 'N/A')
                utilization = gpu.get('utilization.gpu', 'N/A')
                mem_used = gpu.get('memory.used', 'N/A')
                mem_total = gpu.get('memory.total', 'N/A')
                processes = ', '.join([f"{p.get('username', 'N/A')}:{p.get('pid', 'N/A')}" 
                                     for p in gpu.get('processes', [])]) or 'None'
                
                util_color = get_utilization_color(utilization)
                mem_color = get_memory_color(mem_used, mem_total)
                
                html += f"""
                <tr>
                    <td>{index}</td>
                    <td>{name}</td>
                    <td class="util-{util_color}">{utilization}</td>
                    <td class="util-{mem_color}">{mem_used}/{mem_total}</td>
                    <td>{processes}</td>
                </tr>
                """
            html += '</table>'
    
    html += '<div class="cluster-info"><h2>Cluster Job Queue (10.119.48.10)</h2>'
    if isinstance(squeue_status, str):
        html += f'<p class="error">{squeue_status}</p>'
    else:
        total_jobs = squeue_status['total']
        per_user = squeue_status['per_user']
        user_jobs = []
        for name, userid in target_users.items():
            count = per_user.get(userid, 0)
            if count > 0:
                user_jobs.append(f"{name} ({userid}): {count}")
        user_jobs_str = ", ".join(user_jobs) if user_jobs else "None"
        html += f'<p>Total jobs: {total_jobs} ({user_jobs_str})</p>'

    # --- Add resource table---
    html += """
    <h2>Cluster Information</h2>
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
    """

    html += '</div>'
    
    html += """
    </body>
    </html>
    """
    
    return html

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
