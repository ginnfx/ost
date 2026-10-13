import 'server-only';
import { createClient } from '@supabase/supabase-js';

export interface PrivateObjectStore {
  signedReadUrl(key:string,expiresInSeconds:number):Promise<string>;
  signedUploadUrl(key:string):Promise<{url:string;token:string}>;
  remove(keys:string[]):Promise<void>;
}

/** Swap this adapter for R2 without changing competition services. */
export class SupabasePrivateObjectStore implements PrivateObjectStore {
  private readonly client=createClient(required('SUPABASE_URL'),required('SUPABASE_SERVICE_ROLE_KEY'),{auth:{persistSession:false,autoRefreshToken:false,detectSessionInUrl:false}});
  private readonly bucket=required('SUPABASE_STORAGE_BUCKET');

  async signedReadUrl(key:string,expiresInSeconds:number):Promise<string>{
    assertOpaqueStorageKey(key);
    const {data,error}=await this.client.storage.from(this.bucket).createSignedUrl(key,Math.min(Math.max(expiresInSeconds,15),300));
    if(error||!data?.signedUrl) throw new Error('Media could not be made available.');
    return data.signedUrl;
  }
  async signedUploadUrl(key:string):Promise<{url:string;token:string}>{
    assertOpaqueStorageKey(key);
    const {data,error}=await this.client.storage.from(this.bucket).createSignedUploadUrl(key,{upsert:false});
    if(error||!data) throw new Error('Upload could not be started.');
    return {url:data.signedUrl,token:data.token};
  }
  async remove(keys:string[]):Promise<void>{
    if(keys.some(key=>!isOpaqueStorageKey(key))) throw new Error('Media could not be removed.');
    const {error}=await this.client.storage.from(this.bucket).remove(keys);
    if(error) throw new Error('Media could not be removed.');
  }
}

function isOpaqueStorageKey(key:string):boolean{return /^[a-f0-9]{32,64}\/(?:[a-f0-9]{32,64})\.(?:mp4|m4a)$/.test(key);}
function assertOpaqueStorageKey(key:string):void{if(!isOpaqueStorageKey(key))throw new Error('Media is unavailable.');}
function required(name:string):string{const value=process.env[name];if(!value)throw new Error('Server storage configuration is missing.');return value;}
