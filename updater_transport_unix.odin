#+build !windows
package main

import "core:fmt"
import "core:os"
import "core:path/filepath"

updater_unix_fetch_start :: proc(job:^Update_Job,url,path:string,limit:i64)->(os.Process,os.Error) {
    curl:="curl"
    if job.target.os=="linux"&&job.target.kind=="appimage" {
        bundled:=fmt.tprintf("%s/curl",filepath.dir(job.target.executable))
        if os.is_file(bundled) {curl=bundled}
    }
    command:=[]string{curl,"--fail","--silent","--show-error","--location","--max-redirs","4",
        "--proto","=https","--proto-redir","=https","--connect-timeout","10","--max-time","300",
        "--speed-time","30","--speed-limit","1024","--max-filesize",fmt.tprintf("%d",limit),
        "--user-agent","task_master-updater","--output",path,"--",url}
    return os.process_start({command=command})
}
