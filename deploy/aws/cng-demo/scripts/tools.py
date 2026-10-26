"""Verified local tool bootstrap; never modifies system tool installations."""
import hashlib,pathlib,platform,urllib.request,zipfile,shutil,subprocess,json

def download(url,path):
    urllib.request.urlretrieve(url,path)

def terraform_ok(binary):
    """The infra requires Terraform >= 1.16, < 2.0."""
    p=subprocess.run([binary,'version','-json'],capture_output=True,text=True)
    if p.returncode:return False
    major,minor=(int(x) for x in json.loads(p.stdout)['terraform_version'].split('.')[:2])
    return major==1 and minor>=16

def ensure_tools(root,terraform=None):
    folder=pathlib.Path(root)/'.demo-aws/tools';folder.mkdir(parents=True,exist_ok=True)
    system=platform.system().lower();arch={'arm64':'arm64','aarch64':'arm64','x86_64':'amd64'}[platform.machine()]
    tf=terraform or shutil.which('terraform')
    if tf and not terraform and not terraform_ok(tf):tf=None
    if not tf:
        version='1.16.5';name=f'terraform_{version}_{system}_{arch}.zip';target=folder/'terraform';archive=folder/name
        download(f'https://releases.hashicorp.com/terraform/{version}/{name}',archive)
        sums=urllib.request.urlopen(f'https://releases.hashicorp.com/terraform/{version}/terraform_{version}_SHA256SUMS',timeout=30).read().decode()
        wanted=next(line.split()[0] for line in sums.splitlines() if line.endswith(name))
        if hashlib.sha256(archive.read_bytes()).hexdigest()!=wanted:raise ValueError('Terraform checksum mismatch')
        zipfile.ZipFile(archive).extractall(folder);target.chmod(0o755);tf=str(target)
    kubectl=shutil.which('kubectl')
    version=None
    if kubectl:
        p=subprocess.run([kubectl,'version','--client','-o','json'],capture_output=True,text=True)
        if p.returncode==0:version=int(json.loads(p.stdout)['clientVersion']['minor'].rstrip('+'))
    if version not in (34,35,36):
        target=folder/'kubectl-1.35.8'
        if not target.exists():
            url=f'https://dl.k8s.io/release/v1.35.8/bin/{system}/{arch}/kubectl'
            download(url,target);wanted=urllib.request.urlopen(url+'.sha256',timeout=30).read().decode().strip()
            if hashlib.sha256(target.read_bytes()).hexdigest()!=wanted:target.unlink();raise ValueError('kubectl checksum mismatch')
            target.chmod(0o755)
        kubectl=str(target)
    return tf,kubectl
