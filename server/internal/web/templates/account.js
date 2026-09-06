const $=id=>document.getElementById(id);
const msg=(m,kind)=>{const e=$('msg');e.className=kind;e.style.display='block';e.textContent=m};
const esc=s=>String(s||'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const pill=(on,yes,no)=>on?'<span class="pill ok">'+yes+'</span>':'<span class="pill no">'+no+'</span>';
const token=()=>sessionStorage.getItem('token');
async function load(){
  if(!token()){location.href='/login';return}
  try{
    const r=await fetch('/api/account',{headers:{Authorization:'Bearer '+token()}});
    if(!r.ok){sessionStorage.removeItem('token');location.href='/login';return}
    const j=await r.json();
    $('state').textContent='Signed in';
    $('card').style.display='block';
    $('v-email').textContent=j.email;
    $('v-verified').innerHTML=pill(j.emailVerified,'yes','no');
    $('v-2fa').innerHTML=pill(j.totpEnabled,'enabled','off');
    // Admin flag comes from the admin list endpoint; best-effort only.
    try{
      const a=await fetch('/api/admin/users',{headers:{Authorization:'Bearer '+token()}});
      if(a.ok){$('v-role').innerHTML='<span class="pill admin">admin</span>'}
      else{$('v-role').textContent='user'}
    }catch(e){$('v-role').textContent='user'}
  }catch(e){$('state').textContent='Cannot reach the server'}
}
async function signOut(){
  sessionStorage.removeItem('token');
  location.href='/login';
}
async function delAccount(){
  if(!confirm('Permanently delete your account and all synced data? This cannot be undone.'))return;
  if(!confirm('Are you absolutely sure? All your encrypted snapshots will be destroyed.'))return;
  msg('Deleting&hellip;','ok');
  try{
    const r=await fetch('/api/account/delete',{method:'POST',headers:{Authorization:'Bearer '+token()}});
    if(r.ok){
      sessionStorage.removeItem('token');
      location.href='/login?deleted=1';
    }else{
      const j=await r.json();
      msg(j.error||'Delete failed.','err');
    }
  }catch(e){msg('Network error.','err')}
}
load();
