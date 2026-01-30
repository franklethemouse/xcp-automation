#!/usr/bin/env python3
"""
XCP-ng VM Management Agent for Linux
Pulls jobs from central management server via HTTPS

Version: 1.0.3
"""

import os
import sys
import time
import json
import logging
import subprocess
import shutil
from datetime import datetime
from pathlib import Path

VERSION = "1.0.3"
CONFIG_PATH = "/etc/xcp-vm-agent/config.json"
LOG_PATH = "/var/log/xcp-vm-agent"
CHECK_IN_INTERVAL = 30

class VmAgent:
    def __init__(self, config_path):
        self.config = self.load_config(config_path)
        self.agent_id = None
        self.setup_logging()
        
    def load_config(self, path):
        if not os.path.exists(path):
            raise FileNotFoundError(f"Configuration file not found: {path}")
        with open(path, 'r') as f:
            return json.load(f)
    
    def setup_logging(self):
        os.makedirs(LOG_PATH, exist_ok=True)
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s [%(levelname)s] %(message)s',
            handlers=[
                logging.FileHandler(f"{LOG_PATH}/agent.log"),
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger(__name__)
    
    def get_vm_uuid(self):
        """Get VM UUID from XenStore or DMI"""
        try:
            if shutil.which('xenstore-read'):
                result = subprocess.run(
                    ['xenstore-read', 'vm'],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=5
                )
                vm_path = result.stdout.strip()
                uuid = vm_path.split('/')[-1]
                self.logger.info(f"Retrieved VM UUID from XenStore: {uuid}")
                return uuid
        except Exception as e:
            self.logger.warning(f"Failed to get UUID from XenStore: {e}")
        
        try:
            if os.path.exists('/sys/class/dmi/id/product_uuid'):
                with open('/sys/class/dmi/id/product_uuid', 'r') as f:
                    uuid = f.read().strip()
                    self.logger.info(f"Retrieved VM UUID from DMI: {uuid}")
                    return uuid
        except Exception as e:
            self.logger.error(f"Failed to get UUID from DMI: {e}")
        
        return None
    
    def register_agent(self):
        """Register with management server"""
        try:
            import requests
            
            os_info = "Unknown"
            if os.path.exists('/etc/os-release'):
                with open('/etc/os-release') as f:
                    for line in f:
                        if line.startswith('PRETTY_NAME='):
                            os_info = line.split('=', 1)[1].strip('"')
                            break
            
            registration_data = {
                'VmUuid': self.get_vm_uuid(),
                'VmName': os.uname().nodename,
                'Hostname': os.uname().nodename,
                'OsType': 'Linux',
                'OsVersion': os_info,
                'AgentVersion': VERSION,
                'Tags': json.dumps({
                    'kernel': os.uname().release,
                    'architecture': os.uname().machine
                })
            }
            
            if not registration_data['VmUuid']:
                raise ValueError("Unable to determine VM UUID")
            
            request_kwargs = {
                'json': registration_data,
                'timeout': 30
            }
            
            if self.config.get('client_cert'):
                request_kwargs['cert'] = self.config['client_cert']
            if self.config.get('server_cert'):
                request_kwargs['verify'] = self.config['server_cert']
            
            response = requests.post(
                f"{self.config['server_url']}/api/agent/register",
                **request_kwargs
            )
            response.raise_for_status()
            
            self.agent_id = response.json()['AgentId']
            self.logger.info(f"Registered with server. AgentId: {self.agent_id}")
            return True
        except Exception as e:
            self.logger.error(f"Registration failed: {e}")
            return False
    
    def check_in(self):
        """Check in with server and get pending jobs"""
        try:
            import requests
            
            check_in_data = {
                'AgentId': self.agent_id,
                'Timestamp': datetime.utcnow().isoformat()
            }
            
            request_kwargs = {
                'json': check_in_data,
                'timeout': 30
            }
            
            if self.config.get('client_cert'):
                request_kwargs['cert'] = self.config['client_cert']
            if self.config.get('server_cert'):
                request_kwargs['verify'] = self.config['server_cert']
            
            response = requests.post(
                f"{self.config['server_url']}/api/agent/checkin",
                **request_kwargs
            )
            response.raise_for_status()
            
            return response.json().get('Jobs', [])
        except Exception as e:
            self.logger.error(f"Check-in failed: {e}")
            return []
    
    def process_job(self, job):
        """Process a job from the server"""
        job_id = job['JobId']
        job_type = job['JobType']
        
        try:
            self.update_job_status(job_id, 'Running')
            self.logger.info(f"Processing job {job_id}: {job_type}")
            
            parameters = json.loads(job['Parameters'])
            
            if job_type == 'ExtendPartition':
                result = self.extend_partition(parameters)
            elif job_type == 'InitializeDisk':
                result = self.initialize_disk(parameters)
            elif job_type == 'RunScript':
                result = self.run_script(parameters)
            else:
                result = {
                    'Success': False,
                    'Error': f"Unknown job type: {job_type}"
                }
            
            self.submit_job_result(job_id, result)
            self.logger.info(f"Job {job_id} completed: Success={result['Success']}")
            
        except Exception as e:
            error_result = {
                'Success': False,
                'Error': str(e)
            }
            self.submit_job_result(job_id, error_result)
            self.logger.error(f"Job {job_id} failed: {e}")
    
    def extend_partition(self, params):
        """Extend a partition using growpart and resize2fs/xfs_growfs"""
        try:
            device = params['Device']
            partition_number = params['PartitionNumber']
            
            self.logger.info(f"Extending partition {device}{partition_number}")
            
            subprocess.run(
                ['growpart', device, str(partition_number)],
                check=True,
                capture_output=True,
                timeout=60
            )
            
            partition_device = f"{device}{partition_number}"
            fs_type_result = subprocess.run(
                ['blkid', '-s', 'TYPE', '-o', 'value', partition_device],
                capture_output=True,
                text=True,
                check=True,
                timeout=10
            )
            fs_type = fs_type_result.stdout.strip()
            
            if fs_type in ['ext2', 'ext3', 'ext4']:
                subprocess.run(['resize2fs', partition_device], check=True, timeout=300)
            elif fs_type == 'xfs':
                mount_result = subprocess.run(
                    ['findmnt', '-n', '-o', 'TARGET', partition_device],
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=10
                )
                mount_point = mount_result.stdout.strip()
                subprocess.run(['xfs_growfs', mount_point], check=True, timeout=300)
            else:
                return {
                    'Success': False,
                    'Error': f"Unsupported filesystem: {fs_type}"
                }
            
            size_result = subprocess.run(
                ['blockdev', '--getsize64', partition_device],
                capture_output=True,
                text=True,
                check=True,
                timeout=10
            )
            new_size_bytes = int(size_result.stdout.strip())
            new_size_gb = round(new_size_bytes / (1024**3), 2)
            
            return {
                'Success': True,
                'Message': 'Partition extended successfully',
                'Device': partition_device,
                'FileSystem': fs_type,
                'NewSize': new_size_gb
            }
            
        except subprocess.TimeoutExpired:
            return {
                'Success': False,
                'Error': 'Operation timed out'
            }
        except Exception as e:
            return {
                'Success': False,
                'Error': str(e)
            }
    
    def initialize_disk(self, params):
        """Initialize a new disk with partition and filesystem"""
        try:
            device = params['Device']
            mount_point = params['MountPoint']
            fs_type = params.get('FileSystem', 'ext4')
            
            self.logger.info(f"Initializing disk {device} with {fs_type}")
            
            subprocess.run(
                ['parted', '-s', device, 'mklabel', 'gpt'],
                check=True,
                timeout=30
            )
            
            subprocess.run(
                ['parted', '-s', device, 'mkpart', 'primary', fs_type, '0%', '100%'],
                check=True,
                timeout=30
            )
            
            partition_device = f"{device}1"
            time.sleep(2)
            
            if fs_type == 'xfs':
                subprocess.run(['mkfs.xfs', '-f', partition_device], check=True, timeout=300)
            else:
                subprocess.run(['mkfs.ext4', '-F', partition_device], check=True, timeout=300)
            
            os.makedirs(mount_point, exist_ok=True)
            
            uuid_result = subprocess.run(
                ['blkid', '-s', 'UUID', '-o', 'value', partition_device],
                capture_output=True,
                text=True,
                check=True,
                timeout=10
            )
            uuid = uuid_result.stdout.strip()
            
            fstab_entry = f"UUID={uuid} {mount_point} {fs_type} defaults 0 2\n"
            with open('/etc/fstab', 'a') as f:
                f.write(fstab_entry)
            
            subprocess.run(['mount', partition_device], check=True, timeout=30)
            
            size_result = subprocess.run(
                ['blockdev', '--getsize64', partition_device],
                capture_output=True,
                text=True,
                check=True,
                timeout=10
            )
            size_bytes = int(size_result.stdout.strip())
            size_gb = round(size_bytes / (1024**3), 2)
            
            return {
                'Success': True,
                'Message': 'Disk initialized successfully',
                'Device': partition_device,
                'MountPoint': mount_point,
                'FileSystem': fs_type,
                'UUID': uuid,
                'Size': size_gb
            }
            
        except subprocess.TimeoutExpired:
            return {
                'Success': False,
                'Error': 'Operation timed out'
            }
        except Exception as e:
            return {
                'Success': False,
                'Error': str(e)
            }
    
    def run_script(self, params):
        """Execute a custom bash script"""
        try:
            script_content = params['ScriptContent']
            
            self.logger.info("Executing custom bash script")
            
            import tempfile
            with tempfile.NamedTemporaryFile(mode='w', suffix='.sh', delete=False) as f:
                f.write("#!/bin/bash\n")
                f.write(script_content)
                script_path = f.name
            
            os.chmod(script_path, 0o700)
            
            result = subprocess.run(
                ['/bin/bash', script_path],
                capture_output=True,
                text=True,
                timeout=300
            )
            
            os.unlink(script_path)
            
            return {
                'Success': result.returncode == 0,
                'ExitCode': result.returncode,
                'Output': result.stdout,
                'Error': result.stderr if result.returncode != 0 else None
            }
            
        except subprocess.TimeoutExpired:
            return {
                'Success': False,
                'Error': 'Script execution timed out (>5 minutes)'
            }
        except Exception as e:
            return {
                'Success': False,
                'Error': str(e)
            }
    
    def update_job_status(self, job_id, status):
        """Update job status on server"""
        try:
            import requests
            
            status_data = {
                'JobId': job_id,
                'AgentId': self.agent_id,
                'Status': status,
                'Timestamp': datetime.utcnow().isoformat()
            }
            
            request_kwargs = {
                'json': status_data,
                'timeout': 30
            }
            
            if self.config.get('client_cert'):
                request_kwargs['cert'] = self.config['client_cert']
            if self.config.get('server_cert'):
                request_kwargs['verify'] = self.config['server_cert']
            
            requests.post(
                f"{self.config['server_url']}/api/agent/job-status",
                **request_kwargs
            )
        except Exception as e:
            self.logger.warning(f"Failed to update job status: {e}")
    
    def submit_job_result(self, job_id, result):
        """Submit job result to server"""
        try:
            import requests
            
            result_data = {
                'JobId': job_id,
                'AgentId': self.agent_id,
                'Success': result['Success'],
                'Result': json.dumps(result),
                'Timestamp': datetime.utcnow().isoformat()
            }
            
            request_kwargs = {
                'json': result_data,
                'timeout': 30
            }
            
            if self.config.get('client_cert'):
                request_kwargs['cert'] = self.config['client_cert']
            if self.config.get('server_cert'):
                request_kwargs['verify'] = self.config['server_cert']
            
            requests.post(
                f"{self.config['server_url']}/api/agent/job-result",
                **request_kwargs
            )
        except Exception as e:
            self.logger.error(f"Failed to submit job result: {e}")
    
    def run(self):
        """Main agent loop"""
        self.logger.info(f"VM Agent v{VERSION} starting")
        
        if not self.register_agent():
            self.logger.error("Failed to register with server. Will retry...")
        
        while True:
            try:
                if not self.agent_id:
                    if self.register_agent():
                        self.logger.info(f"Successfully registered. AgentId: {self.agent_id}")
                    else:
                        time.sleep(60)
                        continue
                
                jobs = self.check_in()
                
                if jobs:
                    self.logger.info(f"Received {len(jobs)} job(s)")
                    for job in jobs:
                        self.process_job(job)
                
                time.sleep(CHECK_IN_INTERVAL)
                
            except Exception as e:
                self.logger.error(f"Agent loop error: {e}")
                time.sleep(60)

if __name__ == '__main__':
    try:
        agent = VmAgent(CONFIG_PATH)
        agent.run()
    except KeyboardInterrupt:
        print("\nAgent stopped by user")
        sys.exit(0)
    except Exception as e:
        print(f"\nFatal error: {e}")
        sys.exit(1)