# The launcher sets clang, capture_dir, functions, and trace_linux_link.
source_name=
linking=1
lto=0
for arg do
    case "$arg" in
        -E|-M|-MM|-fsyntax-only|-###) exec "$clang" "$@" ;;
        -c|-S|--analyze) linking=0 ;;
        -flto|-flto=*) lto=1 ;;
        -fno-lto) lto=0 ;;
        *.c|*.i) source_name=${arg##*/} ;;
    esac
done

trace_lto=0
if [ "$trace_linux_link" = 1 ] && [ "$linking" = 1 ] && [ "$lto" = 1 ]; then
    plan=$("$clang" "$@" -### 2>&1)
    case "$plan" in
        *'"-plugin" '*LLVMgold.so*) trace_lto=1 ;;
    esac
fi
if [ -z "$source_name" ] && [ "$trace_lto" = 0 ]; then
    exec "$clang" "$@"
fi
if [ -n "$source_name" ]; then
    set -- "$@" -mllvm -print-before-all -mllvm -print-after-all \
        -mllvm "-filter-print-funcs=$functions"
else
    source_name='link-time'
fi
if [ "$trace_lto" = 1 ]; then
    set -- "$@" -v -Xlinker -plugin-opt=-print-before-all \
        -Xlinker -plugin-opt=-print-after-all -Xlinker "-plugin-opt=-filter-print-funcs=$functions"
fi

job=$(mktemp -d "$capture_dir/unit.XXXXXXXX") || exit 1
printf '%s\n' "$source_name" > "$job/source" || exit 1
exec 3>&1
(
    "$clang" "$@" 2>&1 1>&3
    printf '%s\n' "$?" > "$job/status"
) | LC_ALL=C VGUARD_LLVM_JOB="$job" awk -v limit=4194304 -v link_phase="$trace_lto" '
    BEGIN { directory = ENVIRON["VGUARD_LLVM_JOB"] }
    link_phase && /^ "/ && / -plugin / && /LLVMgold\.so/ {
        $0 = "*** VGuard LLVM link-time optimization ***"
        dumping = 1
    }
    link_phase && /^ "/ { next }
    /^[#; ]*\*\*\* IR Dump (Before|After) / { dumping = 1 }
    !dumping || /(^|: )(fatal error|error|warning): / || /^LLVM ERROR:/ {
        print > "/dev/stderr"
    }
    !truncated {
        total += length($0) + 1
        if (total <= limit) {
            print > (directory "/passes.log")
        } else {
            print "limit reached" > (directory "/truncated")
            truncated = 1
        }
    }
' || exit 1
read -r status < "$job/status" || exit 1
exit "$status"
