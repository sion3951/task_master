package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sort"
import "core:strconv"
import "core:strings"

SSH_Discovered_Host :: struct { host, name: string, port: u16, configured: bool }

SSH_Discovery_Record :: struct {
    key: string,
    args: []string,
    include_end: int,
}
SSH_Discovery_State :: struct {
    home, ssh_dir: string,
    records: [dynamic]SSH_Discovery_Record,
    stack: [dynamic]string,
    aliases: [dynamic]string,
    bytes, files: int,
}
SSH_Discovery_Endpoint :: struct { host: string, port: u16 }

ssh_discovery_join :: proc(parts: []string) -> string {
    path, _ := filepath.join(parts, context.temp_allocator)
    return path
}

ssh_discovery_read :: proc(path: string, state: ^SSH_Discovery_State) -> string {
    if state.files >= 256 || state.bytes >= 16*1024*1024 { return "" }
    info, stat_err := os.stat(path, context.temp_allocator)
    if stat_err != nil || info.type != .Regular || info.size < 0 || info.size > 4*1024*1024 || int(info.size)+state.bytes > 16*1024*1024 { return "" }
    file, err := os.open(path)
    if err != nil { return "" }
    defer os.close(file)
    state.files += 1
    buffer := make([]u8, int(info.size), context.temp_allocator)
    used := 0
    for used < len(buffer) {
        n, read_err := os.read(file, buffer[used:])
        if n <= 0 { break }
        used += n
        if read_err != nil { break }
    }
    state.bytes += used
    return string(buffer[:used])
}

// SSH configuration allows quoted tokens and both keyword=value and keyword
// value forms. Comments and escapes are interpreted without invoking a shell.
ssh_discovery_tokens :: proc(line: string) -> []string {
    result := make([dynamic]string, context.temp_allocator)
    token := make([dynamic]u8, context.temp_allocator)
    quote: u8
    escaped := false
    started := false
    for ch,index in transmute([]u8)line {
        when ODIN_OS!=.Windows {_=index}
        if escaped { append(&token, ch); escaped = false; started = true; continue }
        if ch == '\\' {
            when ODIN_OS==.Windows {
                // OpenSSH for Windows accepts native paths. Keep separators
                // unless this backslash actually escapes a token delimiter.
                if index+1<len(line)&&line[index+1]!='"'&&line[index+1]!='\''&&line[index+1]!=' '&&line[index+1]!='\t'&&line[index+1]!='#' {
                    append(&token,ch);started=true;continue
                }
            }
            escaped=true;started=true;continue
        }
        if quote != 0 {
            if ch == quote { quote = 0 } else { append(&token, ch) }
            continue
        }
        if ch == '"' || ch == '\'' { quote = ch; started = true; continue }
        if ch == '#' { break }
        if ch == ' ' || ch == '\t' || ch == '\r' || ch == '=' {
            if started {
                append(&result, strings.clone(string(token[:]), context.temp_allocator))
                clear(&token)
                started = false
            }
        } else { append(&token, ch); started = true }
    }
    if escaped { append(&token, '\\') }
    if quote != 0 { return nil }
    if started { append(&result, strings.clone(string(token[:]), context.temp_allocator)) }
    return result[:]
}

ssh_discovery_plain_host :: proc(host: string) -> bool {
    if len(host) == 0 || len(host) > 255 || host[0] == '-' || host[0] == '!' { return false }
    for ch in host {
        if ch <= 32 || ch >= 127 || ch == '*' || ch == '?' || ch == '[' || ch == ']' || ch == ',' || ch == '#' || ch == '"' || ch == '\'' || ch == '\\' || ch == '/' { return false }
    }
    return true
}

ssh_discovery_add_alias :: proc(state: ^SSH_Discovery_State, host: string) {
    if !ssh_discovery_plain_host(host) || len(state.aliases) >= 4096 { return }
    for old in state.aliases { if strings.equal_fold(old, host) { return } }
    append(&state.aliases, host)
}

ssh_discovery_include_path :: proc(state: ^SSH_Discovery_State, pattern: string) -> string {
    expanded := pattern
    if expanded == "~" { expanded = state.home }
    else if strings.has_prefix(expanded, "~/") {
        expanded = ssh_discovery_join([]string{state.home, expanded[2:]})
    } else if strings.has_prefix(expanded, "~") { return "" }
    if !filepath.is_abs(expanded) { expanded = ssh_discovery_join([]string{state.ssh_dir, expanded}) }
    cleaned, _ := filepath.clean(expanded, context.temp_allocator)
    return cleaned
}

ssh_discovery_config :: proc(state: ^SSH_Discovery_State, path: string, depth: int) {
    if depth >= 16 || len(state.records) >= 65536 { return }
    clean, _ := filepath.clean(path, context.temp_allocator)
    for current in state.stack { if current == clean { return } }
    append(&state.stack, clean)
    defer pop(&state.stack)
    text := ssh_discovery_read(clean, state)
    for line in strings.split_lines_iterator(&text) {
        if len(state.records) >= 65536 { break }
        tokens := ssh_discovery_tokens(line)
        if len(tokens) < 2 { continue }
        key := strings.to_lower(tokens[0], context.temp_allocator)
        args := tokens[1:]
        if key == "host" {
            for alias in args { ssh_discovery_add_alias(state, alias) }
            for &pattern in args { pattern = strings.to_lower(pattern, context.temp_allocator) }
        }
        if key == "include" {
            // Inactive Host/Match sections skip the entire include when aliases
            // are resolved below, while discovery can inspect its concrete Host
            // declarations without guessing wildcard host names.
            start := len(state.records)
            append(&state.records, SSH_Discovery_Record{key = "__include"})
            for pattern in args {
                expanded := ssh_discovery_include_path(state, pattern)
                if expanded == "" { continue }
                paths, err := os.glob(expanded, context.temp_allocator)
                if err != nil { continue }
                sort.quick_sort_proc(paths, proc(a, b: string) -> int { if a < b { return -1 }; if a > b { return 1 }; return 0 })
                for included in paths { ssh_discovery_config(state, included, depth+1) }
            }
            state.records[start].include_end = len(state.records)
            continue
        }
        append(&state.records, SSH_Discovery_Record{key = key, args = args})
    }
}

ssh_discovery_matches :: proc(patterns: []string, host: string) -> bool {
    positive := false
    for pattern in patterns {
        negate := strings.has_prefix(pattern, "!")
        p := pattern
        if negate { p = p[1:] }
        matched, err := os.match(p, host)
        if err != nil || !matched { continue }
        if negate { return false }
        positive = true
    }
    return positive
}

ssh_discovery_port :: proc(text: string) -> (u16, bool) {
    if len(text) == 0 || len(text) > 5 { return 0, false }
    for ch in text { if ch < '0' || ch > '9' { return 0, false } }
    value, ok := strconv.parse_u64(text)
    return u16(value), ok && value > 0 && value <= 65535
}

ssh_discovery_resolve :: proc(state: ^SSH_Discovery_State, alias: string) -> (endpoint: SSH_Discovery_Endpoint, found: bool) {
    lower := strings.to_lower(alias, context.temp_allocator)
    endpoint.host = lower
    endpoint.port = 22
    active := true
    hostname_set, port_set: bool
    for i := 0; i < len(state.records); i += 1 {
        record := state.records[i]
        switch record.key {
        case "__include":
            if !active { i = record.include_end-1 }
        case "host":
            active = ssh_discovery_matches(record.args, lower)
            for pattern in record.args {
                if pattern == lower { found = true }
            }
        case "match":
            // Evaluation involving users, commands, networks or a second
            // canonicalization pass cannot be reproduced by a read-only scan.
            active = len(record.args) == 1 && strings.to_lower(record.args[0], context.temp_allocator) == "all"
        case "hostname":
            if active && !hostname_set && len(record.args) == 1 {
                hostname_set = true
                host, _ := strings.replace_all(record.args[0], "%h", alias, context.temp_allocator)
                host, _ = strings.replace_all(host, "%n", alias, context.temp_allocator)
                if ssh_discovery_plain_host(host) { endpoint.host = strings.to_lower(host, context.temp_allocator) }
            }
        case "port":
            if active && !port_set && len(record.args) == 1 {
                port, ok := ssh_discovery_port(record.args[0])
                if ok { endpoint.port = port; port_set = true }
            }
        }
    }
    return
}

ssh_discovery_known :: proc(state: ^SSH_Discovery_State, path: string, results: ^[dynamic]SSH_Discovered_Host, endpoints: ^[dynamic]SSH_Discovery_Endpoint) {
    text := ssh_discovery_read(path, state)
    for line in strings.split_lines_iterator(&text) {
        if len(results^) >= 4096 { return }
        tokens := ssh_discovery_tokens(line)
        if len(tokens) < 3 { continue }
        field := 0
        if strings.has_prefix(tokens[0], "@") {
            if strings.to_lower(tokens[0], context.temp_allocator) == "@revoked" || len(tokens) < 4 { continue }
            field = 1
        }
        hosts := tokens[field]
        for token in strings.split_iterator(&hosts, ",") {
            if len(results^) >= 4096 { return }
            host := token
            port: u16
            if strings.has_prefix(host, "|") { continue }
            if strings.has_prefix(host, "[") {
                close := strings.last_index(host, "]:")
                if close < 2 { continue }
                parsed, ok := ssh_discovery_port(host[close+2:])
                if !ok { continue }
                port = parsed
                host = host[1:close]
            }
            if !ssh_discovery_plain_host(host) { continue }
            endpoint := SSH_Discovery_Endpoint{host = strings.to_lower(host, context.temp_allocator), port = port}
            if endpoint.port == 0 { endpoint.port = 22 }
            duplicate := false
            for old in endpoints^ { if old == endpoint { duplicate = true; break } }
            if duplicate { continue }
            name := host
            if port != 0 && port != 22 {
                if strings.contains(host, ":") { name = fmt.tprintf("[%s]:%d", host, port) }
                else { name = fmt.tprintf("%s:%d", host, port) }
            }
            append(results, SSH_Discovered_Host{host = host, name = name, port = port})
            append(endpoints, endpoint)
        }
    }
}

// Discover only saved, readable host names. No key material, SSH subprocess,
// Match exec command, DNS lookup or network connection is used here.
ssh_discover_hosts :: proc(home: string) -> []SSH_Discovered_Host {
    if home == "" { return nil }
    state := SSH_Discovery_State{
        home = home, ssh_dir = ssh_discovery_join([]string{home, ".ssh"}),
        records = make([dynamic]SSH_Discovery_Record, context.temp_allocator),
        stack = make([dynamic]string, context.temp_allocator),
        aliases = make([dynamic]string, context.temp_allocator),
    }
    results := make([dynamic]SSH_Discovered_Host, context.temp_allocator)
    endpoints := make([dynamic]SSH_Discovery_Endpoint, context.temp_allocator)
    ssh_discovery_config(&state, ssh_discovery_join([]string{state.ssh_dir, "config"}), 0)
    for alias in state.aliases {
        endpoint, found := ssh_discovery_resolve(&state, alias)
        if !found { continue }
        append(&results, SSH_Discovered_Host{host = alias, name = alias, configured = true})
        append(&endpoints, endpoint)
    }
    ssh_discovery_known(&state, ssh_discovery_join([]string{state.ssh_dir, "known_hosts"}), &results, &endpoints)
    ssh_discovery_known(&state, ssh_discovery_join([]string{state.ssh_dir, "known_hosts2"}), &results, &endpoints)
    return results[:]
}
