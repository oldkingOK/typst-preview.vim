" ============================================================================
" typst-preview.vim - Live preview for Typst documents in Vim
" ============================================================================

if exists('g:loaded_typst_preview')
  finish
endif
let g:loaded_typst_preview = 1

" ============================================================================
" Command Completion Helpers
" ============================================================================

function! s:complete_mode_list(A, L, P) abort
  return ['document', 'slide']
endfunction

" ============================================================================
" Command Implementations
" ============================================================================

function! s:get_current_path() abort
  let path = bufname('%')
  if empty(path)
    call typstpreview#notify_bare('Can not preview an unsaved buffer.', 'error')
    return v:null
  endif
  return path
endfunction

function! s:preview_on(mode) abort
  for bin in typstpreview#bins_to_fetch()
    let dep_bin = get(typstpreview#get_opt('dependencies_bin'), bin['name'], v:null)
    if empty(dep_bin) && !typstpreview#bin_up_to_date(bin)
      let msg = bin['name'] . ' not found or out of date.' . ' Please run :TypstPreviewUpdate first!'
      call typstpreview#notify_bare(msg, 'error')
      return
    endif
  endfor

  let path = s:get_current_path()
  if path is v:null | return | endif

  let path = typstpreview#get_main_file(path)
  let mode = !empty(a:mode) ? a:mode : 'document'

  let sers = typstpreview#server_get(path)
  if empty(sers) || !has_key(sers, mode)
    call typstpreview#server_init(path, mode, function('s:on_server_ready'))
  else
    let s = sers[mode]
    echomsg '[typst-preview] Opening another frontend'
    call typstpreview#visit_link(s['link'])
  endif
endfunction

function! s:on_server_ready(server) abort
  call typstpreview#listen_server_events(a:server)
endfunction

function! s:preview_off() abort
  let path = s:get_current_path()
  if path is v:null | return | endif

  let path = typstpreview#get_main_file(path)
  if typstpreview#server_remove(path)
    echomsg '[typst-preview] Preview stopped'
  else
    echomsg '[typst-preview] Preview not running'
  endif
endfunction

function! s:cmd_preview(args) abort
  if empty(a:args)
    let path = s:get_current_path()
    if path is v:null | return | endif
    let path = typstpreview#get_main_file(path)
    let sers = typstpreview#server_get(path)
    if !empty(sers)
      call s:preview_on(typstpreview#server_get_last_mode(path))
    else
      call s:preview_on('document')
    endif
  else
    let mode = trim(a:args)
    if mode !=# 'document' && mode !=# 'slide'
      let msg = 'Invalid preview mode: "' . mode . '". Should be one of "document" and "slide"'
      call typstpreview#notify_bare(msg, 'error')
      return
    endif
    call s:preview_on(mode)
  endif
endfunction

function! s:cmd_preview_toggle() abort
  let path = s:get_current_path()
  if path is v:null | return | endif
  let path = typstpreview#get_main_file(path)
  if !empty(typstpreview#server_get(path))
    call s:preview_off()
  else
    call s:preview_on(typstpreview#server_get_last_mode(path))
  endif
endfunction

" ============================================================================
" User Commands
" ============================================================================

execute 'command! -nargs=? -complete=customlist,s:complete_mode_list TypstPreview call s:cmd_preview(<q-args>)'
command! -nargs=0 TypstPreviewStop call s:preview_off()
command! -nargs=0 TypstPreviewToggle call s:cmd_preview_toggle()
command! -nargs=0 TypstPreviewUpdate call typstpreview#fetch(0, v:null)
command! -nargs=0 TypstPreviewFollowCursor call typstpreview#set_follow_cursor(1)
command! -nargs=0 TypstPreviewNoFollowCursor call typstpreview#set_follow_cursor(0)
command! -nargs=0 TypstPreviewFollowCursorToggle call typstpreview#set_follow_cursor(!typstpreview#get_follow_cursor())
command! -nargs=0 TypstPreviewSyncCursor call typstpreview#sync_with_cursor()

" ============================================================================
" Initialize Events
" ============================================================================

call typstpreview#events_init()
