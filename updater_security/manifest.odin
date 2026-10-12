package updater_security

import "core:crypto/ed25519"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

PUBLIC_KEY :: string(#load("../assets/update-public-key.hex"))
REPOSITORY :: "https://github.com/sion3951/task_master/releases/download/"
MAX_PACKAGE :: i64(1024*1024*1024)
Asset :: struct {os,arch,kind,name,sha256,url:string,size:i64}
Manifest :: struct {schema:int,version:string,assets:[]Asset}

// Both the desktop and the protected installer use this trust policy. Verify
// the exact signed bytes before parsing any asset names, hashes or versions.
verify_manifest :: proc(data,signature:[]u8)->(Manifest,bool) {
    bytes:[32]u8
    key:ed25519.Public_Key
    if len(data)==0||len(data)>65536||len(signature)!=64||!hex(PUBLIC_KEY,bytes[:])||
        !ed25519.public_key_set_bytes(&key,bytes[:])||!ed25519.verify(&key,data,signature) {return {},false}
    manifest:Manifest
    if json.unmarshal(data,&manifest,allocator=context.temp_allocator)!=nil||manifest.schema!=1 {return {},false}
    return manifest,true
}

// Stable releases only, with numeric comparison (1.10.0 > 1.9.0).
version_parse :: proc(input:string)->([3]u64,bool) {
    value:=strings.trim_space(input)
    if strings.has_prefix(value,"v") {value=value[1:]}
    if at:=strings.index(value,"+");at>=0 {
        metadata:=value[at+1:]
        if len(metadata)==0||metadata[0]=='.'||metadata[len(metadata)-1]=='.'||strings.contains(metadata,"..") {return {},false}
        for c in transmute([]u8)metadata {
            if !((c>='0'&&c<='9')||(c>='A'&&c<='Z')||(c>='a'&&c<='z')||c=='-'||c=='.') {return {},false}
        }
        value=value[:at]
    }
    parts:=strings.split(value,".",context.temp_allocator)
    result:[3]u64
    if len(parts)!=3 {return result,false}
    for part,i in parts {
        if len(part)==0||len(part)>18||(len(part)>1&&part[0]=='0') {return result,false}
        for c in transmute([]u8)part {if c<'0'||c>'9' {return result,false};result[i]=result[i]*10+u64(c-'0')}
    }
    return result,true
}
version_newer :: proc(candidate,current:string)->(bool,bool) {
    remote,rok:=version_parse(candidate)
    local_value:=strings.trim_space(current)
    if at:=strings.index(local_value,"+");at>=0 {local_value=local_value[:at]}
    prerelease:=false
    if at:=strings.index(local_value,"-");at>=0 {
        if at==len(local_value)-1 {return false,false}
        prerelease=true;local_value=local_value[:at]
    }
    local,lok:=version_parse(local_value)
    if !rok||!lok {return false,false}
    for i in 0..<3 {if remote[i]!=local[i] {return remote[i]>local[i],true}}
    return prerelease,true
}
hex :: proc(input:string,out:[]u8)->bool {
    value:=strings.trim_space(input)
    if len(value)!=len(out)*2 {return false}
    for &byte,i in out {
        v:u8
        for c in transmute([]u8)value[i*2:i*2+2] {
            v*=16
            if c>='0'&&c<='9' {v+=c-'0'} else if c>='a'&&c<='f' {v+=c-'a'+10} else {return false}
        }
        byte=v
    }
    return true
}
url_component :: proc(value:string)->string {
    builder:=strings.builder_make(context.temp_allocator)
    digits:="0123456789ABCDEF"
    for c in transmute([]u8)value {
        if (c>='0'&&c<='9')||(c>='A'&&c<='Z')||(c>='a'&&c<='z')||c=='-'||c=='_'||c=='.'||c=='~' {
            strings.write_byte(&builder,c)
        } else {
            strings.write_byte(&builder,'%');strings.write_byte(&builder,digits[c>>4]);strings.write_byte(&builder,digits[c&15])
        }
    }
    return strings.to_string(builder)
}
release_url :: proc(url,tag,name:string)->bool {
    if name==""||len(name)>240||strings.contains_any(name,"/\\\r\n\t?#%")||name=="."||name==".." {return false}
    // The release publisher escapes '+' in SemVer build metadata. GitHub may
    // return its equivalent unescaped URL in discovery metadata.
    canonical:=fmt.tprintf("%s%s/%s",REPOSITORY,url_component(tag),url_component(name))
    return url==canonical||url==fmt.tprintf("%s%s/%s",REPOSITORY,tag,name)
}
