#!/usr/bin/env bash

if [[ -z $1 ]]; then
    echo "Usage: ./run.sh program_file [--quiet]"
    exit 1
fi

PROGRAM="$1"
QUIET=0

if [[ $2 == "--quiet" ]]; then
    QUIET=1
fi

# number of parallel jobs (can override with MAX_JOBS env var)
MAX_JOBS=${MAX_JOBS:-$(( $(nproc) ))}

mkdir -p mutants
mkdir -p mutants/alive
mkdir -p mutants/timed-out
mkdir -p mutants/killed

echo "|- Processing $PROGRAM for mutation targets -"

dotnet ./dafny/Binaries/Dafny.dll verify "$PROGRAM" \
    --allow-warnings \
    --solver-path ./dafny/Binaries/z3 \
    --plugin ./mutdafny/bin/Debug/net8.0/mutdafny.dll,scan \
    > /dev/null

IFS=','
readarray -t targets < targets.csv

TOTAL=${#targets[@]}

echo 0 > progress.tmp
touch progress.lock

base=$(basename "$PROGRAM" .dfy)

process_target() {

    target="$1"

    IFS=',' read -ra target_args <<< "$target"
    pos=${target_args[0]}
    op=${target_args[1]}
    arg=${target_args[2]}

    if [[ -z $arg ]]; then
        [[ $QUIET -eq 0 ]] && echo "Mutating position $pos: operator $op"

        output=$(dotnet ./dafny/Binaries/Dafny.dll verify "$PROGRAM" \
            --allow-warnings \
            --solver-path ./dafny/Binaries/z3 \
            --plugin ./mutdafny/bin/Debug/net8.0/mutdafny.dll,"mut $pos $op" \
            2>/dev/null)
    else
        [[ $QUIET -eq 0 ]] && echo "Mutating position $pos: operator $op, argument $arg"

        output=$(dotnet ./dafny/Binaries/Dafny.dll verify "$PROGRAM" \
            --allow-warnings \
            --solver-path ./dafny/Binaries/z3 \
            --plugin ./mutdafny/bin/Debug/net8.0/mutdafny.dll,"mut $pos $op $arg" \
            2>/dev/null)
    fi

    verification_finished=$(echo "$output" | grep "Dafny program verifier finished")
    verified=$(echo "$output" | grep "Dafny program verifier finished.*0 errors")
    timed_out=$(echo "$output" | grep "Dafny program verifier finished.*time out")
    output_line=$(echo "$output" | tail -1)

    if [[ -z $arg ]]; then
        item_out_name="${base}__${pos}_${op}.dfy"
    else
        item_out_name="${base}__${pos}_${op}_${arg}.dfy"
    fi

    if [[ -z $verification_finished ]]; then
        rm -f "$item_out_name"
        [[ $QUIET -eq 0 ]] && echo "Error: mutant is invalid"
    else

        if [[ -n $timed_out ]]; then
            output_dir="mutants/timed-out"
        elif [[ -n $verified ]]; then
            output_dir="mutants/alive"
        else
            output_dir="mutants/killed"
        fi

        mv "$item_out_name" "$output_dir"

        if [[ $QUIET -eq 0 ]]; then
            COLOR='\033[0;31m'
            [[ -n $verified ]] && COLOR='\033[0m'
            echo -e "${COLOR}${output_line}\033[0m"
        fi
    fi

    # progress update (thread safe)
    (
        flock 200
        count=$(<progress.tmp)
        count=$((count + 1))
        echo "$count" > progress.tmp
        printf "\r|- Program mutation: %d/%d" "$count" "$TOTAL"
    ) 200>progress.lock
}

export -f process_target
export PROGRAM QUIET base TOTAL

for target in "${targets[@]}"; do
(
    process_target "$target"
) &

while [[ $(jobs -r -p | wc -l) -ge $MAX_JOBS ]]; do
    wait -n
done

done

wait

echo
echo

rm -f progress.tmp progress.lock targets.csv elapsed-time.csv