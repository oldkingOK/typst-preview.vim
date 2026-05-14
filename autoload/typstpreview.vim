" ============================================================================
" typstpreview.vim - Autoload functions for typst-preview.vim
" ============================================================================

" ============================================================================
" Section: Configuration
" ============================================================================

let s:opts = {}
let s:opts['debug'] = 0
let s:opts['open_cmd'] = v:null
let s:opts['port'] = 0
let s:opts['host'] = '127.0.0.1'
let s:opts['invert_colors'] = 'never'
let s:opts['follow_cursor'] = 1
let s:opts['dependencies_bin'] = {'tinymist': v:null, 'websocat': v:null}
let s:opts['extra_args'] = v:null

function! s:default_get_root(path_of_main_file) abort
  let env_root = $TYPST_ROOT
  if !empty(env_root)
    return env_root
  endif
  let main_dir = fnamemodify(a:path_of_main_file, ':p:h')
  for marker in ['typst.toml', '.git']
    let found = findfile(marker, main_dir . ';')
    if !empty(found)
      return fnamemodify(found, ':p:h')
    endif
  endfor
  return main_dir
endfunction

function! s:default_get_main_file(path) abort
  return a:path
endfunction

function! s:get_root(path_of_main_file) abort
  if has_key(s:opts, 'get_root') && type(s:opts['get_root']) == v:t_func
    return s:opts['get_root'](a:path_of_main_file)
  endif
  return s:default_get_root(a:path_of_main_file)
endfunction

function! s:get_main_file(path) abort
  if has_key(s:opts, 'get_main_file') && type(s:opts['get_main_file']) == v:t_func
    return s:opts['get_main_file'](a:path)
  endif
  return a:path
endfunction

function! typstpreview#setup(opts) abort
  if !empty(a:opts)
    call s:deep_extend(s:opts, a:opts)
  endif
  call typstpreview#update(1)
endfunction

function! typstpreview#set_follow_cursor(enabled) abort
  let s:opts['follow_cursor'] = a:enabled ? 1 : 0
endfunction

function! typstpreview#get_follow_cursor() abort
  return s:opts['follow_cursor']
endfunction

" ============================================================================
" Section: Platform Detection
" ============================================================================

function! s:is_windows() abort
  return has('win32') || has('win64')
endfunction

function! s:is_macos() abort
  return has('mac') || has('macunix')
endfunction

function! s:is_linux() abort
  return has('unix') && !s:is_macos()
endfunction

function! s:is_wsl() abort
  if !s:is_linux() | return 0 | endif
  return system('uname -r 2>/dev/null') =~? 'microsoft'
endfunction

function! s:is_x64() abort
  if s:is_windows() | return 1 | endif
  let machine = substitute(system('uname -m 2>/dev/null'), '\n\+$', '', '')
  return machine ==# 'x86_64'
endfunction

function! s:is_arm64() abort
  let machine = substitute(system('uname -m 2>/dev/null'), '\n\+$', '', '')
  return machine ==# 'aarch64' || machine ==# 'aarch64_be' || machine ==# 'armv8b' || machine ==# 'armv8l' || machine ==# 'arm64'
endfunction

" ============================================================================
" Section: Utilities
" ============================================================================

function! s:get_data_path() abort
  let base = !empty($XDG_DATA_HOME) ? $XDG_DATA_HOME : expand('~/.local/share')
  return fnamemodify(base . '/vim/typst-preview/', ':p')
endfunction

call mkdir(s:get_data_path(), 'p')

let s:log_path = s:get_data_path() . 'log.txt'

function! s:visit(link) abort
  let url = 'http://' . a:link
  if !empty(get(s:opts, 'open_cmd', v:null))
    let cmd_str = printf(s:opts['open_cmd'], url)
    call job_start(cmd_str, {})
    return
  endif
  if s:is_macos()
    call job_start(['open', url], {})
  elseif s:is_windows()
    call job_start(['explorer.exe', url], {})
  elseif s:is_wsl()
    call job_start(['wslview', url], {})
  else
    call job_start(['xdg-open', url], {})
  endif
endfunction

function! s:file_exists(path) abort
  return filereadable(a:path)
endfunction

function! s:notify(msg, level) abort
  call timer_start(0, function('s:do_notify', [a:msg, a:level]))
endfunction

function! s:do_notify(msg, level, timer) abort
  if a:level ==# 'error'
    echohl ErrorMsg
    echomsg '[typst-preview] ' . a:msg
    echohl None
  else
    echomsg '[typst-preview] ' . a:msg
  endif
endfunction

function! s:print_deferred(msg) abort
  call timer_start(0, function('s:do_print', [a:msg]))
endfunction

function! s:do_print(msg, timer) abort
  echomsg '[typst-preview] ' . a:msg
endfunction

function! s:debug(msg) abort
  if !s:opts['debug'] | return | endif
  if !filereadable(s:log_path)
    call writefile([], s:log_path, '')
  endif
  call writefile([a:msg], s:log_path, 'a')
endfunction

function! s:get_buf_content(bufnr) abort
  return join(getbufline(a:bufnr, 1, '$'), "\n")
endfunction

function! s:get_buf_path(bufnr) abort
  return fnamemodify(bufname(a:bufnr), ':p')
endfunction

function! s:deep_extend(dest, src) abort
  for [key, val] in items(a:src)
    if type(val) == v:t_dict && type(get(a:dest, key)) == v:t_dict
      call s:deep_extend(a:dest[key], val)
    else
      let a:dest[key] = val
    endif
  endfor
endfunction

function! s:noop(...) abort
endfunction

" ============================================================================
" Section: Binary Fetch
" ============================================================================

let s:tinymist_bin_name = v:null
let s:websocat_bin_name = v:null
let s:record_path = s:get_data_path() . 'version_record.txt'

function! s:resolve_bin_name(map) abort
  let osname = ''
  if s:is_macos()
    let osname = 'macos'
  elseif s:is_linux()
    let osname = 'linux'
  elseif s:is_windows()
    let osname = 'windows'
  endif
  let machine = ''
  if s:is_x64()
    let machine = 'x64'
  elseif s:is_arm64()
    let machine = 'arm64'
  endif
  if empty(osname) || empty(machine) || !has_key(a:map[osname], machine)
    call s:notify("typst-preview can't figure out your platform. Please report this bug.", 'error')
    return v:null
  endif
  return a:map[osname][machine]
endfunction

function! s:get_tinymist_bin_name() abort
  if s:tinymist_bin_name is v:null
    let m = {}
    let m['macos'] = {'arm64': 'tinymist-darwin-arm64', 'x64': 'tinymist-darwin-x64'}
    let m['linux'] = {'arm64': 'tinymist-linux-arm64', 'x64': 'tinymist-linux-x64'}
    let m['windows'] = {'arm64': 'tinymist-win32-arm64.exe', 'x64': 'tinymist-win32-x64.exe'}
    let s:tinymist_bin_name = s:resolve_bin_name(m)
  endif
  return s:tinymist_bin_name
endfunction

function! s:get_websocat_bin_name() abort
  if s:websocat_bin_name is v:null
    let m = {}
    let m['macos'] = {'arm64': 'websocat.aarch64-apple-darwin', 'x64': 'websocat.x86_64-apple-darwin'}
    let m['linux'] = {'arm64': 'websocat.aarch64-unknown-linux-musl', 'x64': 'websocat.x86_64-unknown-linux-musl'}
    let m['windows'] = {'x64': 'websocat.x86_64-pc-windows-gnu.exe'}
    let s:websocat_bin_name = s:resolve_bin_name(m)
  endif
  return s:websocat_bin_name
endfunction

function! s:bin_up_to_date(bin) abort
  if !s:file_exists(s:get_data_path() . a:bin['bin_name'])
    return 0
  endif
  if !filereadable(s:record_path)
    return 0
  endif
  for line in readfile(s:record_path)
    if line ==# a:bin['url']
      return 1
    endif
  endfor
  return 0
endfunction

let s:fetch_state = {}

function! s:download_bin(bin_name, bin_url, bin_path, quiet, Callback) abort
  let dep_bin = get(s:opts['dependencies_bin'], a:bin_name, v:null)
  if !empty(dep_bin)
    if !a:quiet
      call s:print_deferred("Binary for '" . a:bin_name . "' has been provided in config. Please ensure manually that it is up to date.")
    endif
    call a:Callback(0)
    return
  endif

  let check_bin = {'name': a:bin_name, 'bin_name': fnamemodify(a:bin_path, ':t'), 'url': a:bin_url}
  if s:bin_up_to_date(check_bin)
    if !a:quiet
      call s:print_deferred(a:bin_name . ' already up to date.')
    endif
    call a:Callback(0)
    return
  endif

  let cmd = ['curl', '-L', a:bin_url, '--create-dirs', '--output', a:bin_path, '--progress-bar']
  let job_opts = {}
  let job_opts['out_cb'] = function('s:on_curl_out', [a:bin_name])
  let job_opts['err_cb'] = function('s:on_curl_err', [a:bin_name])
  let job_opts['exit_cb'] = function('s:on_curl_exit', [a:bin_name, a:bin_path, a:Callback])
  let job_opts['out_mode'] = 'raw'
  let job_opts['err_mode'] = 'raw'
  let job = job_start(cmd, job_opts)
  if job_status(job) ==# 'fail'
    call s:notify('Launching curl failed. Make sure curl is installed on your system.', 'error')
  endif
endfunction

function! s:on_curl_out(bin_name, channel, data) abort
  let progress = substitute(a:data, '.*\r', '', '')
  call s:print_deferred('Downloading ' . a:bin_name . ' ' . progress)
endfunction

function! s:on_curl_err(bin_name, channel, data) abort
  let progress = substitute(a:data, '.*\r', '', '')
  call s:print_deferred('Downloading ' . a:bin_name . ' ' . progress)
endfunction

function! s:on_curl_exit(bin_name, bin_path, Callback, job, status) abort
  if a:status != 0
    call s:notify('Downloading ' . a:bin_name . ' binary failed, exit code: ' . a:status, 'error')
  else
    if !s:is_windows()
      call job_start(['chmod', '+x', a:bin_path], {'exit_cb': function('s:on_chmod_done', [a:Callback])})
    else
      call a:Callback(1)
    endif
  endif
endfunction

function! s:on_chmod_done(Callback, job, status) abort
  call a:Callback(1)
endfunction

function! s:bins_to_fetch() abort
  let result = []
  call add(result, {'url': 'https://github.com/Myriad-Dreamin/tinymist/releases/download/v0.14.12/' . s:get_tinymist_bin_name(), 'bin_name': s:get_tinymist_bin_name(), 'name': 'tinymist'})
  call add(result, {'url': 'https://github.com/vi/websocat/releases/download/v1.14.0/' . s:get_websocat_bin_name(), 'bin_name': s:get_websocat_bin_name(), 'name': 'websocat'})
  return result
endfunction

function! typstpreview#update(quiet) abort
  call typstpreview#fetch(a:quiet, v:null)
endfunction

function! typstpreview#fetch(quiet, Callback) abort
  let bins = s:bins_to_fetch()
  let s:fetch_state = {}
  let s:fetch_state['downloaded'] = 0
  let s:fetch_state['Callback'] = !empty(a:Callback) ? a:Callback : function('s:noop')
  let s:fetch_state['bins'] = copy(bins)
  let s:fetch_state['index'] = 0
  let s:fetch_state['quiet'] = a:quiet
  call s:fetch_next_bin()
endfunction

function! s:fetch_next_bin() abort
  if s:fetch_state['index'] >= len(s:fetch_state['bins'])
    call s:fetch_finish()
    return
  endif
  let bin = s:fetch_state['bins'][s:fetch_state['index']]
  let s:fetch_state['index'] += 1
  let bin_path = s:get_data_path() . bin['bin_name']
  call s:download_bin(bin['name'], bin['url'], bin_path, s:fetch_state['quiet'], function('s:on_fetch_bin_done'))
endfunction

function! s:on_fetch_bin_done(did_download) abort
  if a:did_download
    let s:fetch_state['downloaded'] += 1
  endif
  call s:fetch_next_bin()
endfunction

function! s:fetch_finish() abort
  if s:fetch_state['downloaded'] > 0
    call s:print_deferred('All binaries required by typst-preview downloaded to ' . s:get_data_path())
  endif
  let rec_bins = []
  for b in s:bins_to_fetch()
    if empty(get(s:opts['dependencies_bin'], b['name'], v:null))
      call add(rec_bins, b)
    endif
  endfor
  let lines = []
  for b in rec_bins
    call add(lines, b['url'])
  endfor
  call writefile(lines, s:record_path)
  call s:fetch_state['Callback']()
endfunction

" ============================================================================
" Section: Server Factory (Process Spawning)
" ============================================================================

let s:next_spawn_id = 0
let s:spawns = {}

function! s:spawn(path, host, port, mode, Callback) abort
  let id = s:next_spawn_id
  let s:next_spawn_id += 1

  if !empty(get(s:opts['dependencies_bin'], 'tinymist', v:null))
    let tinymist_bin = s:opts['dependencies_bin']['tinymist']
  else
    let tinymist_bin = s:get_data_path() . s:get_tinymist_bin_name()
  endif

  let args = ['preview']
  call add(args, '--invert-colors')
  call add(args, s:opts['invert_colors'])
  call add(args, '--preview-mode')
  call add(args, a:mode)
  call add(args, '--no-open')
  call add(args, '--data-plane-host')
  call add(args, a:host . ':0')
  call add(args, '--control-plane-host')
  call add(args, a:host . ':0')
  call add(args, '--static-file-host')
  call add(args, a:host . ':' . a:port)
  call add(args, '--root')
  call add(args, s:get_root(a:path))

  if !empty(get(s:opts, 'extra_args', v:null))
    let extra = s:opts['extra_args']
    if type(extra) == v:t_func
      try
        let res = extra(a:path, a:mode, a:port)
        if type(res) == v:t_list
          call extend(args, res)
        elseif type(res) == v:t_string && !empty(res)
          call add(args, res)
        endif
      catch
      endtry
    elseif type(extra) == v:t_list
      call extend(args, extra)
    endif
  endif

  call add(args, s:get_main_file(a:path))

  call s:debug('spawning server ' . tinymist_bin . ' with args:')
  call s:debug(string(args))

  let s:spawns[id] = {}
  let s:spawns[id]['path'] = a:path
  let s:spawns[id]['host'] = a:host
  let s:spawns[id]['port'] = a:port
  let s:spawns[id]['mode'] = a:mode
  let s:spawns[id]['Callback'] = a:Callback
  let s:spawns[id]['tinymist_job'] = v:null
  let s:spawns[id]['websocat_job'] = v:null
  let s:spawns[id]['websocat_channel'] = v:null
  let s:spawns[id]['control_host'] = v:null
  let s:spawns[id]['static_host'] = v:null
  let s:spawns[id]['start_time'] = reltime()
  let s:spawns[id]['websocat_data'] = ''
  let s:spawns[id]['callback_param'] = v:null
  let s:spawns[id]['connected'] = 0
  let s:spawns[id]['link_set'] = 0

  let job_opts = {}
  let job_opts['out_cb'] = function('s:on_tinymist_output', [id])
  let job_opts['err_cb'] = function('s:on_tinymist_error', [id])
  let job_opts['exit_cb'] = function('s:on_tinymist_exit', [id])
  let job_opts['out_mode'] = 'raw'
  let job_opts['err_mode'] = 'raw'
  let job = job_start([tinymist_bin] + args, job_opts)
  if job_status(job) ==# 'fail'
    call s:notify('Failed to start tinymist: ' . tinymist_bin, 'error')
    return
  endif
  let s:spawns[id]['tinymist_job'] = job
endfunction

function! s:on_tinymist_output(id, channel, data) abort
  if !has_key(s:spawns, a:id) | return | endif
  call s:process_tinymist_output(a:id, a:data)
endfunction

function! s:on_tinymist_error(id, channel, data) abort
  if !has_key(s:spawns, a:id) | return | endif
  call s:debug('tinymist stderr: ' . a:data)
  call s:process_tinymist_output(a:id, a:data)
endfunction

function! s:on_tinymist_exit(id, job, status) abort
  if !has_key(s:spawns, a:id) | return | endif
  let sd = s:spawns[a:id]
  let elapsed = reltimefloat(reltime(sd['start_time']))
  if elapsed < 0.1
    call s:print_deferred('tinymist exited within 0.1 second of starting, please set debug = true and check ' . s:log_path . ' for more details')
  endif
endfunction

function! s:process_tinymist_output(id, data) abort
  if !has_key(s:spawns, a:id) | return | endif
  let sd = s:spawns[a:id]

  call s:debug('tinymist: ' . a:data)

  " Check for AddrInUse -> retry with port + 1
  if a:data =~# 'AddrInUse'
    call s:print_deferred('Port ' . sd['port'] . ' is already in use')
    call s:spawn(sd['path'], sd['host'], sd['port'] + 1, sd['mode'], sd['Callback'])
    return
  endif

  " Look for control-plane host
  if !sd['connected']
    let ctrl_match = matchstr(a:data, 'Control \(plane\|panel\) server listening on:\s*\zs[^\n]\+')
    if !empty(ctrl_match)
      let sd['control_host'] = substitute(ctrl_match, '\s\+', '', 'g')
      let sd['connected'] = 1
      call s:debug('Connecting to server at ' . sd['control_host'])
      call s:connect_websocat(a:id, sd['control_host'])
    endif
  endif

  " Look for static-file host
  if !sd['link_set']
    let static_match = matchstr(a:data, 'Static file server listening on:\s*\zs[^\n]\+')
    if !empty(static_match)
      let sd['static_host'] = substitute(static_match, '\s\+', '', 'g')
      let sd['link_set'] = 1
      call s:debug('Setting link to ' . sd['static_host'])
      call timer_start(0, function('s:on_static_host_found', [a:id, sd['static_host']]))
    endif
  endif
endfunction

function! s:connect_websocat(id, control_host) abort
  if !has_key(s:spawns, a:id) | return | endif
  let sd = s:spawns[a:id]

  if !empty(get(s:opts['dependencies_bin'], 'websocat', v:null))
    let websocat_bin = s:opts['dependencies_bin']['websocat']
  else
    let websocat_bin = s:get_data_path() . s:get_websocat_bin_name()
  endif

  let addr = 'ws://' . a:control_host . '/'
  call s:debug('websocat connecting to: ' . addr)

  let ws_opts = {}
  let ws_opts['out_cb'] = function('s:on_websocat_output', [a:id])
  let ws_opts['err_cb'] = function('s:on_websocat_stderr', [a:id])
  let ws_opts['in_mode'] = 'raw'
  let ws_opts['out_mode'] = 'raw'
  let ws_opts['err_mode'] = 'raw'
  let ws_job = job_start([websocat_bin, '-B', '10000000', '--origin', 'http://localhost', addr], ws_opts)
  if job_status(ws_job) ==# 'fail'
    call s:notify('Failed to start websocat: ' . websocat_bin, 'error')
    return
  endif

  let sd['websocat_job'] = ws_job
  let sd['websocat_channel'] = job_getchannel(ws_job)

  " Build callback param dict with close/write/read functions
  let param = {}
  let param['close'] = function('s:server_close', [a:id])
  let param['write'] = function('s:server_write', [a:id])
  let param['read'] = function('s:server_read_setup', [a:id])

  if type(sd['callback_param']) == v:t_string && !empty(sd['callback_param'])
    " Static host was found first -> fire callback now
    let link = sd['callback_param']
    call sd['Callback'](param['close'], param['write'], param['read'], link)
  else
    let sd['callback_param'] = param
  endif
endfunction

function! s:on_static_host_found(id, static_host, timer) abort
  if !has_key(s:spawns, a:id) | return | endif
  let sd = s:spawns[a:id]

  call s:visit(a:static_host)

  if type(sd['callback_param']) == v:t_dict
    " Websocat already connected -> fire callback now
    let param = sd['callback_param']
    call sd['Callback'](param['close'], param['write'], param['read'], a:static_host)
  else
    let sd['callback_param'] = a:static_host
  endif
endfunction

function! s:on_websocat_output(id, channel, data) abort
  if !has_key(s:spawns, a:id) | return | endif
  let sd = s:spawns[a:id]

  call s:debug('websocat said: ' . a:data)

  let sd['websocat_data'] .= a:data

  " Parse newline-delimited JSON messages
  while 1
    let nl = stridx(sd['websocat_data'], "\n")
    if nl < 0 | break | endif
    let line = sd['websocat_data'][:nl - 1]
    let sd['websocat_data'] = sd['websocat_data'][nl + 1:]

    try
      let event = json_decode(line)
    catch
      call s:debug('Failed to decode JSON: ' . line)
      continue
    endtry

    if type(event) == v:t_dict && has_key(event, 'event')
      call s:dispatch_server_event(sd, event)
    endif
  endwhile

  if !empty(sd['websocat_data'])
    call s:debug('Leaving for next read: ' . sd['websocat_data'])
  endif
endfunction

function! s:on_websocat_stderr(id, channel, data) abort
  call s:debug('websocat stderr: ' . a:data)
endfunction

function! s:dispatch_server_event(sd, event) abort
  let listeners = get(a:sd, 'event_listeners', {})
  let handler_list = get(listeners, a:event['event'], [])
  for Handler in handler_list
    call Handler(a:event)
  endfor
endfunction

function! s:server_close(id, ...) abort
  if !has_key(s:spawns, a:id) | return | endif
  let sd = s:spawns[a:id]
  if !empty(sd['tinymist_job']) && job_status(sd['tinymist_job']) ==# 'run'
    call job_stop(sd['tinymist_job'], 'kill')
  endif
  if !empty(sd['websocat_job']) && job_status(sd['websocat_job']) ==# 'run'
    call job_stop(sd['websocat_job'], 'kill')
  endif
endfunction

function! s:server_write(id, data) abort
  if !has_key(s:spawns, a:id) | return | endif
  let sd = s:spawns[a:id]
  call ch_sendraw(sd['websocat_channel'], a:data)
endfunction

function! s:server_read_setup(id, callback) abort
  if !has_key(s:spawns, a:id) | return | endif
  let s:spawns[a:id]['read_callback'] = a:callback
endfunction

" ============================================================================
" Section: Server Management
" ============================================================================

let s:servers = {}
let s:last_modes = {}

function! typstpreview#server_get_last_mode(path) abort
  let abs = fnamemodify(a:path, ':p')
  return get(s:last_modes, abs, 'document')
endfunction

function! typstpreview#server_init(path, mode, Callback) abort
  let abs = fnamemodify(a:path, ':p')
  if has_key(s:servers, abs) && has_key(s:servers[abs], a:mode)
    call s:notify('Server with path ' . abs . ' and mode ' . a:mode . ' already exists.', 'error')
    return
  endif
  call s:spawn(abs, s:opts['host'], s:opts['port'], a:mode, function('s:on_server_spawned', [abs, a:mode, a:Callback]))
endfunction

function! s:on_server_spawned(path, mode, Callback, close, write, read, link) abort
  let server = {}
  let server['path'] = a:path
  let server['mode'] = a:mode
  let server['link'] = a:link
  let server['suppress'] = 0
  let server['close'] = a:close
  let server['write'] = a:write
  let server['read_callback'] = a:read
  let server['event_listeners'] = {}
  if !has_key(s:servers, a:path)
    let s:servers[a:path] = {}
  endif
  let s:servers[a:path][a:mode] = server
  let s:last_modes[a:path] = a:mode
  call a:Callback(server)
endfunction

function! typstpreview#server_get(path) abort
  let abs = fnamemodify(a:path, ':p')
  return get(s:servers, abs, {})
endfunction

function! typstpreview#server_get_all() abort
  let result = []
  for [_, modes] in items(s:servers)
    for [_, server] in items(modes)
      call add(result, server)
    endfor
  endfor
  return result
endfunction

function! typstpreview#server_remove(path) abort
  let abs = fnamemodify(a:path, ':p')
  if !has_key(s:servers, abs) | return 0 | endif
  let removed = 0
  for [mode, server] in items(s:servers[abs])
    call server['close']()
    call s:debug('Server with path ' . abs . ' and mode ' . mode . ' closed.')
    call remove(s:servers[abs], mode)
    let removed = 1
  endfor
  if removed
    call remove(s:servers, abs)
  endif
  return removed
endfunction

function! typstpreview#server_remove_all() abort
  for path in keys(s:servers)
    call typstpreview#server_remove(path)
  endfor
endfunction

" ============================================================================
" Section: Server API (Memory Files & Cursor Sync)
" ============================================================================

function! typstpreview#server_update_memory_file(server, path, content) abort
  if a:server['suppress'] | return | endif
  call s:debug('updating file: ' . a:path . ', main path: ' . a:server['path'])
  let msg = json_encode({'event': 'updateMemoryFiles', 'files': {a:path: a:content}}) . "\n"
  call a:server['write'](msg)
endfunction

function! typstpreview#server_remove_memory_file(server, path) abort
  if a:server['suppress'] | return | endif
  call s:debug('removing file: ' . a:path)
  let msg = json_encode({'event': 'removeMemoryFiles', 'files': [a:path]}) . "\n"
  call a:server['write'](msg)
endfunction

function! typstpreview#server_sync_with_cursor(server) abort
  if a:server['suppress'] | return | endif
  let line_num = line('.') - 1
  let col_num = col('.') - 1
  call s:debug('scroll to line: ' . line_num . ', character: ' . col_num)
  let scroll_event = {}
  let scroll_event['event'] = 'panelScrollTo'
  let scroll_event['filepath'] = s:get_buf_path(bufnr('%'))
  let scroll_event['line'] = line_num
  let scroll_event['character'] = col_num
  let msg = json_encode(scroll_event) . "\n"
  call a:server['write'](msg)
endfunction

" ============================================================================
" Section: Server Event Listeners (editorScrollTo)
" ============================================================================

function! typstpreview#server_listen_scroll(server, Handler) abort
  let listeners = a:server['event_listeners']
  if !has_key(listeners, 'editorScrollTo')
    let listeners['editorScrollTo'] = []
  endif
  call add(listeners['editorScrollTo'], function('s:wrap_scroll_event', [a:Handler]))
endfunction

function! s:wrap_scroll_event(Handler, event) abort
  let wrapped = {}
  let wrapped['filepath'] = a:event['filepath']
  let wrapped['start'] = {'row': a:event['start'][0], 'column': a:event['start'][1]}
  let wrapped['end_'] = {'row': a:event['end'][0], 'column': a:event['end'][1]}
  call a:Handler(wrapped)
endfunction

function! s:handle_editor_scroll_to(server, event) abort
  call s:debug(a:event['end_']['row'] . ' ' . a:event['end_']['column'])
  let a:server['suppress'] = 1
  call s:do_editor_scroll_to(a:server, a:event)
endfunction

function! s:do_editor_scroll_to(server, event) abort
  let row = a:event['end_']['row'] + 1
  let max_row = line('$')
  if row < 1 | let row = 1 | endif
  if row > max_row | let row = max_row | endif

  let column = a:event['end_']['column'] - 1
  let max_column = col('$') - 1
  if column < 0 | let column = 0 | endif
  if column > max_column | let column = max_column | endif

  let filepath = a:event['filepath']
  if filepath !=# s:get_buf_path(bufnr('%'))
    execute 'e ' . fnameescape(filepath)
    call timer_start(100, function('s:do_set_cursor_and_unsuppress', [row, column, a:server]))
  else
    call cursor(row, column)
    call timer_start(100, function('s:do_unsuppress', [a:server]))
  endif
endfunction

function! s:do_set_cursor_and_unsuppress(row, column, server, timer) abort
  call cursor(a:row, a:column)
  call timer_start(100, function('s:do_unsuppress', [a:server]))
endfunction

function! s:do_unsuppress(server, timer) abort
  let a:server['suppress'] = 0
endfunction

" ============================================================================
" Section: Autocmd Setup (Editor Events)
" ============================================================================

function! typstpreview#register_buffer_autocmds(bufnr) abort
  call s:debug('Registering autocmds for buffer ' . a:bufnr)
  augroup typstpreview_buffer
    execute 'autocmd! * <buffer=' . a:bufnr . '>'
    execute 'autocmd TextChanged,TextChangedI,TextChangedP,InsertLeave <buffer=' . a:bufnr . '> call typstpreview#on_text_changed(' . a:bufnr . ')'
    execute 'autocmd CursorMoved <buffer=' . a:bufnr . '> call typstpreview#on_cursor_moved(' . a:bufnr . ')'
  augroup END
endfunction

function! typstpreview#on_text_changed(bufnr) abort
  let path = s:get_buf_path(a:bufnr)
  if empty(path) | return | endif
  let content = s:get_buf_content(a:bufnr)
  for server in typstpreview#server_get_all()
    call typstpreview#server_update_memory_file(server, path, content)
  endfor
endfunction

function! typstpreview#on_cursor_moved(bufnr) abort
  if !typstpreview#get_follow_cursor() | return | endif
  let current_line = line('.')
  if exists('b:typstpreview_last_line') && b:typstpreview_last_line == current_line
    return
  endif
  let b:typstpreview_last_line = current_line
  for server in typstpreview#server_get_all()
    call typstpreview#server_sync_with_cursor(server)
  endfor
endfunction

" ============================================================================
" Section: Event Init (Public Entry for Autocmd Registration)
" ============================================================================

function! typstpreview#events_init() abort
  augroup typstpreview_global
    autocmd!
    autocmd FileType typst call typstpreview#on_filetype_typst(expand('<abuf>'))
    autocmd VimLeavePre * call typstpreview#server_remove_all()
  augroup END

  " Register for existing typst buffers
  for info in getbufinfo()
    if getbufvar(info['bufnr'], '&filetype') ==# 'typst'
      call typstpreview#register_buffer_autocmds(info['bufnr'])
    endif
  endfor
endfunction

function! typstpreview#on_filetype_typst(bufnr) abort
  call typstpreview#register_buffer_autocmds(str2nr(a:bufnr))
endfunction

" ============================================================================
" Section: Public API
" ============================================================================

function! typstpreview#sync_with_cursor() abort
  for server in typstpreview#server_get_all()
    call typstpreview#server_sync_with_cursor(server)
  endfor
endfunction

function! typstpreview#listen_server_events(server) abort
  call typstpreview#server_listen_scroll(a:server, function('s:handle_editor_scroll_to', [a:server]))
endfunction

function! typstpreview#notify_bare(msg, level) abort
  call s:notify(a:msg, a:level)
endfunction

function! typstpreview#bins_to_fetch() abort
  return s:bins_to_fetch()
endfunction

function! typstpreview#bin_up_to_date(bin) abort
  return s:bin_up_to_date(a:bin)
endfunction

function! typstpreview#get_opt(key) abort
  return get(s:opts, a:key, v:null)
endfunction

function! typstpreview#get_main_file(path) abort
  return s:get_main_file(a:path)
endfunction

function! typstpreview#visit_link(link) abort
  call s:visit(a:link)
endfunction
