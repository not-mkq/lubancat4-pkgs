# Fish completion for lubancat4-set-default.
complete -c lubancat4-set-default -f -n '__fish_is_first_token' -a 'arch' -d 'Set mainline kernel as the default boot entry'
complete -c lubancat4-set-default -f -n '__fish_is_first_token' -a 'bsp' -d 'Set BSP kernel as the default boot entry'
complete -c lubancat4-set-default -l help -s h -d 'Show usage information'
