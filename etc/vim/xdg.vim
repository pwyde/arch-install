
" XDG Base Directory locations, appended to /etc/vimrc by base-install.sh.
" archlinux.vim, sourced above, already keeps swap, backup and undo files in
" the cache directory. The viminfo file with the history, registers and marks
" moves from ~/.viminfo to the state directory, and netrw's bookmarks and
" history from ~/.vim to the data directory.
let s:state_dir = $HOME . '/.local/state/vim'
if !empty($XDG_STATE_HOME)
  let s:state_dir = $XDG_STATE_HOME . '/vim'
endif
let s:data_dir = $HOME . '/.local/share/vim'
if !empty($XDG_DATA_HOME)
  let s:data_dir = $XDG_DATA_HOME . '/vim'
endif
for s:dir in [s:state_dir, s:data_dir]
  if !isdirectory(s:dir)
    silent! call mkdir(s:dir, 'p', 0700)
  endif
endfor
let &viminfofile = s:state_dir . '/viminfo'
let g:netrw_home = s:data_dir
unlet s:state_dir s:data_dir s:dir
