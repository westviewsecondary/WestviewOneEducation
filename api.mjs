const cfg=window.ONEEDUCATION_CONFIG;
let session=null;try{session=JSON.parse(sessionStorage.getItem('oneeducation-staff-session')||'null')}catch{}
export const identity=()=>session?.user;
function store(s){session={...s,expires_at:Math.floor(Date.now()/1000)+(s.expires_in||3600)};sessionStorage.setItem('oneeducation-staff-session',JSON.stringify(session))}
async function request(path,body,auth=true){
 if(auth&&session&&session.expires_at<Date.now()/1000+60){const r=await fetch(cfg.supabaseUrl+'/auth/v1/token?grant_type=refresh_token',{method:'POST',headers:{apikey:cfg.supabaseKey,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:session.refresh_token})});const fresh=await r.json();if(!r.ok){signOut();throw Error('Your session has expired. Please sign in again.')}store(fresh)}
 const headers={apikey:cfg.supabaseKey,'Content-Type':'application/json'};if(auth){if(!session)throw Error('Please sign in.');headers.Authorization='Bearer '+session.access_token}
 let r;try{r=await fetch(cfg.supabaseUrl+path,{method:'POST',headers,body:JSON.stringify(body)})}catch{throw Error('Cannot reach OneEducation. Check your internet connection; your changes have not been saved.')}
 const data=await r.json().catch(()=>null);if(!r.ok){const msg=data?.message||data?.msg||data?.error_description||'Request failed';if(/Could not find the function|schema cache/.test(msg))throw Error('Database setup is needed. Run ONEEDUCATION-SETUP.sql in the new Supabase project first.');throw Error(msg)}return data;
}
export async function signIn(email,password){store(await request('/auth/v1/token?grant_type=password',{email,password},false));try{return await rpc('oe_get_state')}catch(e){signOut();throw e}}
export function signOut(){const token=session?.access_token;session=null;sessionStorage.removeItem('oneeducation-staff-session');if(token)fetch(cfg.supabaseUrl+'/auth/v1/logout',{method:'POST',headers:{apikey:cfg.supabaseKey,Authorization:'Bearer '+token}}).catch(()=>{})}
export const rpc=(name,body={})=>request('/rest/v1/rpc/'+name,body);
export const portal=code=>request('/rest/v1/rpc/oe_student_portal',{p_code:code},false);
export const studentAction=(code,kind,data,item=null)=>request('/rest/v1/rpc/oe_hub_student_action',{p_code:code,p_kind:kind,p_data:data,p_item:item},false);
