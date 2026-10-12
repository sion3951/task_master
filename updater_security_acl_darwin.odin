#+build darwin
package main

import "core:strings"
import "core:sys/posix"

// ABI/constants: apple-oss-distributions/Libc include/sys/acl.h.
foreign import updater_acl_system "system:System"
foreign updater_acl_system {
    @(link_name="acl_get_file")
    updater_acl_get_file :: proc "c" (path:cstring,kind:i32)->rawptr ---
    @(link_name="acl_get_entry")
    updater_acl_get_entry :: proc "c" (acl:rawptr,position:i32,entry:^rawptr)->i32 ---
    @(link_name="acl_get_tag_type")
    updater_acl_get_tag_type :: proc "c" (entry:rawptr,tag:^i32)->i32 ---
    @(link_name="acl_get_permset_mask_np")
    updater_acl_get_permissions :: proc "c" (entry:rawptr,permissions:^u64)->i32 ---
    @(link_name="acl_free")
    updater_acl_free :: proc "c" (acl:rawptr)->i32 ---
}

// macOS ACLs can grant write/replace rights despite a root-owned 0755 mode.
// Accept read-only and deny entries, but reject grants that could modify this
// code, its owner/ACL or an ancestor directory.
updater_darwin_protected_acl :: proc(path:string)->bool {
    acl:=updater_acl_get_file(strings.clone_to_cstring(path,context.temp_allocator),0x100)
    if acl==nil {return posix.get_errno()==.ENOENT} // no ACL property
    defer updater_acl_free(acl)
    position:=i32(0) // ACL_FIRST_ENTRY; ACL_NEXT_ENTRY is -1 on macOS.
    for _ in 0..<129 {
        entry:rawptr
        // Unlike Linux, macOS returns 0 for success and EINVAL at the end.
        if updater_acl_get_entry(acl,position,&entry)!=0 {return posix.get_errno()==.EINVAL}
        position=-1
        tag:i32
        permissions:u64
        if updater_acl_get_tag_type(entry,&tag)!=0||updater_acl_get_permissions(entry,&permissions)!=0 {return false}
        write_rights :: u64((1<<2)|(1<<4)|(1<<5)|(1<<6)|(1<<8)|(1<<10)|(1<<12)|(1<<13))
        if tag!=1&&tag!=2 {return false}
        if tag==1&&permissions&write_rights!=0 {return false} // ACL_EXTENDED_ALLOW
    }
    return false
}
