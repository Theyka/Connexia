const $=id=>document.getElementById(id);
const esc=s=>String(s||'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const fmt=n=>n>=1048576?(n/1048576).toFixed(1)+' MB':n>=1024?(n/1024).toFixed(1)+' KB':n+' B';
const errMsg=(m)=>{const e=$('msg');e.className='err';e.style.display='block';e.textContent=m};
const okMsg=(m)=>{const e=$('msg');e.className='ok';e.style.display='block';e.textContent=m};
const clearMsg=()=>{$('msg').style.display='none'};
function show(id){for(const v of ['setup','login'])$(v).classList.add('hidden');$(id).classList.remove('hidden');clearMsg()}
async function api(path,opts){
  const r=await fetch(path,opts);
  let json={};
  try{json=await r.json()}catch(e){}
  return {ok:r.ok,status:r.status,json};
}

async function init(){
  const {json}=await api('/api/setup/status');
  if(json.adminExists){
    const token=sessionStorage.getItem('token');
    if(token){try{const u=await loadUsers(token);if(u)return}catch(e){}}
    show('login');
  }else{
    show('setup');
  }
}

async function createAdmin(){
  clearMsg();
  const email=$('s-email').value.trim(),pass=$('s-pass').value,p2=$('s-pass2').value;
  if(!email||!pass){errMsg('Enter an email and password.');return}
  if(pass.length<8){errMsg('Password must be at least 8 characters.');return}
  if(pass!==p2){errMsg('Passwords do not match.');return}
  const {ok,json}=await api('/api/register',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password:pass})});
  if(!ok){errMsg(json.error||'Registration failed.');return}
  if(!json.isAdmin){errMsg('An admin account already exists — please sign in instead.');return}
  $('l-email').value=email;
  $('l-pass').value=pass;
  show('login');
  okMsg('Admin account created. Sign in below.');
}

async function login(){
  clearMsg();
  const email=$('l-email').value.trim(),pass=$('l-pass').value;
  const {ok,json}=await api('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,password:pass})});
  if(!ok){errMsg(json.error||'Invalid email or password.');return}
  sessionStorage.setItem('token',json.token);
  const loaded=await loadUsers(json.token);
  if(!loaded){sessionStorage.removeItem('token')}
}

async function loadUsers(token){
  const {ok,json}=await api('/api/admin/users',{headers:{Authorization:'Bearer '+(token||sessionStorage.getItem('token'))}});
  if(!ok){show('login');errMsg('This account is not an admin.');return false}
  const users=json.users||[];
  $('rows').innerHTML=users.map(u=>
    '<tr><td class="email">'+esc(u.email)+'</td>'+
    '<td class="muted">'+esc((u.createdAt||'').replace('T',' ').slice(0,19))+'</td>'+
    '<td>'+(u.isAdmin?'<span class="pill admin">admin</span>':'<span class="muted">user</span>')+'</td>'+
    '<td>'+(u.emailVerified?'<span class="pill ok">yes</span>':'<span class="pill no">no</span>')+'</td>'+
    '<td>'+(u.totpEnabled?'<span class="pill ok">yes</span>':'<span class="pill no">no</span>')+'</td>'+
    '<td>'+u.sessions+'</td>'+
    '<td class="muted">'+fmt(u.blobBytes)+'</td>'+
    '<td class="acts">'+
      '<button class="mini" onclick="toggleRole(\''+u.id+'\','+(!u.isAdmin)+')">'+(u.isAdmin?'Demote':'Make admin')+'</button> '+
      '<button class="mini danger" onclick="delUser(\''+u.id+'\')">Delete</button>'+
    '</td></tr>'
  ).join('');
  $('summary').textContent=users.length+' account(s) — '+users.filter(u=>u.isAdmin).length+' admin(s), '+fmt(users.reduce((a,u)=>a+u.blobBytes,0))+' encrypted.';
  $('summary').style.display='block';
  $('tblwrap').style.display='block';
  $('tbl').style.display='table';
  $('topbar').style.display='flex';
  await loadSettings();
  return true;
}

async function loadSettings(){
  const {ok,json}=await api('/api/admin/settings',{headers:{Authorization:'Bearer '+sessionStorage.getItem('token')}});
  if(!ok)return;
  $('req-verify').checked=!!json.requireEmailVerification;
  $('web-ssh').checked=!!json.webSSHEnabled;
  $('web-ssh-private').checked=!!json.webSSHAllowPrivate;
  $('settings').style.display='block';
}

function bindSetting(id,key,describe){
  $(id).addEventListener('change',async()=>{
    clearMsg();
    const {ok,json}=await api('/api/admin/settings',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+sessionStorage.getItem('token')},body:JSON.stringify({[key]:$(id).checked})});
    if(!ok){$(id).checked=!$(id).checked;errMsg(json.error||'Failed to save setting.');return}
    okMsg('Saved — '+describe(json[key])+'.');
  });
}
bindSetting('req-verify','requireEmailVerification',on=>'new registrations '+(on?'must verify their email':'are verified immediately'));
bindSetting('web-ssh','webSSHEnabled',on=>'web SSH is '+(on?'on':'off'));
bindSetting('web-ssh-private','webSSHAllowPrivate',on=>'web SSH '+(on?'can':'can no longer')+' reach private and local addresses');

async function delUser(id){
  if(!confirm('Delete this account and all its synced data? This cannot be undone.'))return;
  const {ok,json}=await api('/api/admin/users/delete',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+sessionStorage.getItem('token')},body:JSON.stringify({id})});
  if(!ok){errMsg(json.error||'Delete failed.');return}
  okMsg('Account deleted.');
  await loadUsers();
}

async function toggleRole(id,isAdmin){
  const {ok,json}=await api('/api/admin/users/role',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+sessionStorage.getItem('token')},body:JSON.stringify({id,isAdmin})});
  if(!ok){errMsg(json.error||'Failed to change role.');return}
  okMsg('Role updated.');
  await loadUsers();
}

function logout(){
  sessionStorage.removeItem('token');
  $('topbar').style.display='none';
  $('tblwrap').style.display='none';
  $('summary').style.display='none';
  $('settings').style.display='none';
  show('login');
}
$('s-pass').addEventListener('keydown',e=>{if(e.key==='Enter')createAdmin()});
$('l-pass').addEventListener('keydown',e=>{if(e.key==='Enter')login()});
init();
