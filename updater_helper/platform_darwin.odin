#+build darwin
package main

foreign import helper_system "system:System"
foreign helper_system {
    @(link_name="sysctlbyname")
    helper_sysctlbyname :: proc "c" (name:cstring,output:rawptr,size:^uintptr,input:rawptr,input_size:uintptr)->i32 ---
}

// Match the desktop's hardware choice when an Intel installation runs through
// Rosetta. The native package's Installer preflight uses the physical Mac too.
helper_darwin_native_architecture :: proc(compiled_arch:string)->string {
    arm64:i32
    size:=uintptr(size_of(arm64))
    if helper_sysctlbyname("hw.optional.arm64",&arm64,&size,nil,0)==0&&arm64==1 {return "arm64"}
    return compiled_arch
}
