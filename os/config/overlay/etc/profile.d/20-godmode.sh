# Interactive-shell conveniences.
case $- in *i*) ;; *) return ;; esac
export PATH="/opt/node/bin:$PATH"
alias ll='ls -alh'
alias fd='fdfind'
