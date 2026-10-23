
" XDG Base Directory locations, appended to /etc/vimrc by arch-install.sh.
" archlinux.vim, sourced above, already keeps swap, backup and undo files in
" the cache directory. The viminfo file with the history, registers and marks
" moves from ~/.viminfo to the state directory, and netrw's bookmarks and
" history from ~/.vim to the data directory.
let s:state_dir = (exists('$XDG_STATE_HOME') ? $XDG_STATE_HOME : $HOME . '/.local/state') . '/vim'
let s:data_dir = (exists('$XDG_DATA_HOME') ? $XDG_DATA_HOME : $HOME . '/.local/share') . '/vim'
for s:dir in [s:state_dir, s:data_dir]
  if !isdirectory(s:dir)
    silent! call mkdir(s:dir, 'p', 0700)
  endif
endfor
let &viminfofile = s:state_dir . '/viminfo'
let g:netrw_home = s:data_dir
unlet s:state_dir s:data_dir s:dir
