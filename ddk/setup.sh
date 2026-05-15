#!/bin/sh
set -eu

GKI_ROOT="$(pwd)"
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/xingguang-ddk"
PATCH_DIR="$SCRIPT_DIR/patches/xingguang-ddk"
DDK_DIR="$GKI_ROOT/Xingguang-DDK"

if [ -d "$GKI_ROOT/security" ]; then
	COMMON_ROOT="$GKI_ROOT"
	SECURITY_DIR="$GKI_ROOT/security"
elif [ -d "$GKI_ROOT/common/security" ]; then
	COMMON_ROOT="$GKI_ROOT/common"
	SECURITY_DIR="$GKI_ROOT/common/security"
else
	echo '[ERROR] security directory not found.'
	exit 127
fi

SECURITY_MAKEFILE="$SECURITY_DIR/Makefile"
SECURITY_KCONFIG="$SECURITY_DIR/Kconfig"
DDK_SYMLINK="$SECURITY_DIR/xingguang-ddk"

if [ ! -d "$SRC_DIR" ]; then
	echo "[ERROR] DDK source directory not found: $SRC_DIR"
	exit 127
fi

function_has_call() {
	file="$1"
	signature="$2"
	marker="$3"
	awk -v signature="$signature" -v marker="$marker" '
		$0 ~ "^[[:space:]]*" signature "\\(" { in_func=1 }
		in_func && index($0, marker) { found=1; exit }
		in_func && /^}/ { exit }
		END { exit found ? 0 : 1 }
	' "$file"
}

function_has_call_name() {
	file="$1"
	name="$2"
	marker="$3"
	awk -v name="$name" -v marker="$marker" '
		$0 ~ "^[[:space:]]*([_[:alnum:]]+[[:space:]*]+)+" name "[[:space:]]*\\(" { in_func=1 }
		in_func && index($0, marker) { found=1; exit }
		in_func && /^}/ { exit }
		END { exit found ? 0 : 1 }
	' "$file"
}

inject_function_entry_guard() {
	file="$1"
	name="$2"
	marker="$3"
	call="$4"

	python3 - "$file" "$name" "$marker" "$call" <<'PY'
import re
import sys

path, name, marker, call = sys.argv[1:]

with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

sig_re = re.compile(
    r"^\s*(?:[A-Za-z_][\w\s\*]*\s+)+" + re.escape(name) + r"\s*\("
)
brace_line = None
i = 0
while i < len(lines):
    if sig_re.search(lines[i]):
        j = i
        while j < len(lines):
            if ";" in lines[j] and "{" not in lines[j]:
                break
            if "{" in lines[j]:
                brace_line = j
                break
            j += 1
        if brace_line is not None:
            break
        i = j
    i += 1

if brace_line is None:
    raise SystemExit(f"{name} anchor not found")

depth = 0
end_line = None
for i in range(brace_line, len(lines)):
    depth += lines[i].count("{") - lines[i].count("}")
    if i > brace_line and depth == 0:
        end_line = i + 1
        break

if end_line is None:
    raise SystemExit(f"{name} body end not found")

if marker in "".join(lines[brace_line:end_line]):
    raise SystemExit(0)

decl_re = re.compile(
    r"^\s*(?:"
    r"const\s+|volatile\s+|static\s+|struct\s+|union\s+|enum\s+|"
    r"unsigned\s+|signed\s+|long\s+|short\s+|int\s+|bool\s+|char\s+|"
    r"void\s+|size_t\s+|ssize_t\s+|loff_t\s+|sector_t\s+|gfp_t\s+|"
    r"blk_mode_t\s+|fmode_t\s+|umode_t\s+|u\d+\s+|s\d+\s+|"
    r"[A-Za-z_]\w*_t\s+|[A-Za-z_]\w+\s+\*"
    r")"
)

decl_end = brace_line + 1
in_decl = False
in_comment = False
while decl_end < end_line:
    stripped = lines[decl_end].strip()
    if in_comment:
        if "*/" in stripped:
            in_comment = False
        decl_end += 1
        continue
    if stripped == "":
        decl_end += 1
        continue
    if stripped.startswith("/*"):
        if "*/" not in stripped:
            in_comment = True
        decl_end += 1
        continue
    if in_decl:
        if ";" in stripped:
            in_decl = False
        decl_end += 1
        continue
    if decl_re.match(lines[decl_end]):
        if ";" not in stripped:
            in_decl = True
        decl_end += 1
        continue
    break

guard = [
    f"\txg_ddk_ret = {call};\n",
    "\tif (xg_ddk_ret)\n",
    "\t\treturn xg_ddk_ret;\n",
    "\n",
]

new_lines = (
    lines[: brace_line + 1]
    + ["\tint xg_ddk_ret;\n"]
    + lines[brace_line + 1 : decl_end]
    + guard
    + lines[decl_end:]
)

with open(path, "w", encoding="utf-8") as f:
    f.writelines(new_lines)
PY
}

apply_ddk_0010_compat() {
	read_write_file="$COMMON_ROOT/fs/read_write.c"

	ensure_ddk_include_after_includes "$read_write_file" || return 1

	python3 - "$read_write_file" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()


def find_function(name):
    sig_re = re.compile(
        r"^\s*(?:[A-Za-z_][\w\s\*]*\s+)+" + re.escape(name) + r"\s*\("
    )
    brace_line = None
    i = 0
    while i < len(lines):
        if sig_re.search(lines[i]):
            j = i
            while j < len(lines):
                if ";" in lines[j] and "{" not in lines[j]:
                    break
                if "{" in lines[j]:
                    brace_line = j
                    break
                j += 1
            if brace_line is not None:
                break
            i = j
        i += 1

    if brace_line is None:
        return None

    depth = 0
    for i in range(brace_line, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if i > brace_line and depth == 0:
            return brace_line, i + 1
    return None


def insert_after_rw_verify(name, marker, call):
    found = find_function(name)
    if not found:
        return False
    brace_line, end_line = found
    body = "".join(lines[brace_line:end_line])
    if marker in body:
        return True

    rw_line = None
    for i in range(brace_line, end_line):
        line = lines[i]
        if "ret = rw_verify_area(WRITE, file," in line:
            rw_line = i
            break
    if rw_line is None:
        raise SystemExit(f"{name} rw_verify_area write anchor not found")

    insert_at = rw_line + 1
    while insert_at < end_line and lines[insert_at].strip() == "":
        insert_at += 1
    if insert_at < end_line and re.match(r"\s*if\s*\(\s*ret(?:\s*<\s*0)?\s*\)", lines[insert_at]):
        check_line = insert_at
        insert_at += 1
        while insert_at < end_line and lines[insert_at].strip() == "":
            insert_at += 1
        if insert_at < end_line and re.match(r"\s*return\s+ret\s*;", lines[insert_at]):
            insert_at += 1
        else:
            insert_at = check_line

    lines[insert_at:insert_at] = [
        f"\tret = {call};\n",
        "\tif (ret)\n",
        "\t\treturn ret;\n",
        "\n",
    ]
    return True


if not insert_after_rw_verify(
    "vfs_write",
    "xg_ddk_vfs_write(file, buf, count, pos)",
    "xg_ddk_vfs_write(file, buf, count, pos)",
):
    raise SystemExit("vfs_write anchor not found")

iter_hooked = False
for name, call in (
    ("do_iter_write", "xg_ddk_vfs_iter_write(file, iter, pos)"),
    ("vfs_iter_write", "xg_ddk_vfs_iter_write(file, iter, ppos)"),
):
    if insert_after_rw_verify(name, call, call):
        iter_hooked = True

if not iter_hooked:
    raise SystemExit("iter write anchor not found")

if not insert_after_rw_verify(
    "vfs_iocb_iter_write",
    "xg_ddk_vfs_iter_write(file, iter, &iocb->ki_pos)",
    "xg_ddk_vfs_iter_write(file, iter, &iocb->ki_pos)",
):
    raise SystemExit("vfs_iocb_iter_write anchor not found")

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY

	function_has_call_name "$read_write_file" "vfs_write" "xg_ddk_vfs_write(file, buf, count, pos)" || return 1
	if ! function_has_call_name "$read_write_file" "do_iter_write" "xg_ddk_vfs_iter_write(file, iter, pos)" &&
		! function_has_call_name "$read_write_file" "vfs_iter_write" "xg_ddk_vfs_iter_write(file, iter, ppos)"; then
		return 1
	fi
	function_has_call_name "$read_write_file" "vfs_iocb_iter_write" "xg_ddk_vfs_iter_write(file, iter, &iocb->ki_pos)" || return 1
}

ensure_ddk_include() {
	file="$1"
	include='#include <linux/xingguang_ddk.h>'

	if [ ! -f "$file" ]; then
		echo "[ERROR] DDK target file not found: $file"
		return 1
	fi

	if grep -qF "$include" "$file"; then
		return 0
	fi

	if ! grep -q '^#include "blk.h"$' "$file"; then
		echo "[ERROR] DDK include anchor not found in $file"
		return 1
	fi

	sed -i '/^#include "blk.h"$/a\
#include <linux/xingguang_ddk.h>' "$file"
}

ensure_ddk_include_after_includes() {
	file="$1"
	include='#include <linux/xingguang_ddk.h>'

	if [ ! -f "$file" ]; then
		echo "[ERROR] DDK target file not found: $file"
		return 1
	fi

	if grep -qF "$include" "$file"; then
		return 0
	fi

	awk -v inc_line="$include" '
		{ lines[NR] = $0 }
		/^#include[[:space:]]+[<"]/ { last_include = NR }
		END {
			if (!last_include)
				exit 1
			for (i = 1; i <= NR; i++) {
				print lines[i]
				if (i == last_include)
					print inc_line
			}
		}
	' "$file" > "$file.xg-ddk.tmp" && mv "$file.xg-ddk.tmp" "$file" && return 0

	rm -f "$file.xg-ddk.tmp"
	echo "[ERROR] DDK include anchor not found in $file"
	return 1
}

inject_ioctl_after_declarations() {
	file="$1"
	name="$2"

	python3 - "$file" "$name" <<'PY'
import re
import sys

path, name = sys.argv[1:]

with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

sig_re = re.compile(
    r"^\s*(?:[A-Za-z_][\w\s\*]*\s+)+" + re.escape(name) + r"\s*\("
)
brace_line = None
i = 0
while i < len(lines):
    if sig_re.search(lines[i]):
        j = i
        while j < len(lines):
            if ";" in lines[j] and "{" not in lines[j]:
                break
            if "{" in lines[j]:
                brace_line = j
                break
            j += 1
        if brace_line is not None:
            break
        i = j
    i += 1

if brace_line is None:
    raise SystemExit(f"{name} anchor not found")

depth = 0
end_line = None
for i in range(brace_line, len(lines)):
    depth += lines[i].count("{") - lines[i].count("}")
    if i > brace_line and depth == 0:
        end_line = i + 1
        break

if end_line is None:
    raise SystemExit(f"{name} body end not found")

body = "".join(lines[brace_line:end_line])
if "xg_ddk_blkdev_ioctl(bdev, cmd)" in body:
    raise SystemExit(0)

decl_re = re.compile(
    r"^\s*(?:"
    r"const\s+|volatile\s+|static\s+|struct\s+|union\s+|enum\s+|"
    r"unsigned\s+|signed\s+|long\s+|short\s+|int\s+|bool\s+|char\s+|"
    r"void\s+|size_t\s+|ssize_t\s+|loff_t\s+|sector_t\s+|gfp_t\s+|"
    r"blk_mode_t\s+|fmode_t\s+|umode_t\s+|u\d+\s+|s\d+\s+|"
    r"[A-Za-z_]\w*_t\s+|[A-Za-z_]\w+\s+\*"
    r")"
)

insert_at = brace_line + 1
in_decl = False
in_comment = False
while insert_at < end_line:
    stripped = lines[insert_at].strip()
    if in_comment:
        if "*/" in stripped:
            in_comment = False
        insert_at += 1
        continue
    if stripped == "":
        insert_at += 1
        continue
    if stripped.startswith("/*"):
        if "*/" not in stripped:
            in_comment = True
        insert_at += 1
        continue
    if in_decl:
        if ";" in stripped:
            in_decl = False
        insert_at += 1
        continue
    if decl_re.match(lines[insert_at]):
        if ";" not in stripped:
            in_decl = True
        insert_at += 1
        continue
    break

lines[insert_at:insert_at] = [
    "\tret = xg_ddk_blkdev_ioctl(bdev, cmd);\n",
    "\tif (ret)\n",
    "\t\treturn ret;\n",
    "\n",
]

with open(path, "w", encoding="utf-8") as f:
    f.writelines(lines)
PY
}

inject_blkdev_ioctl_compat() {
	file="$1"

	inject_ioctl_after_declarations "$file" "blkdev_ioctl" && return 0
	inject_ioctl_after_ret_and_bdev "$file" "blkdev_ioctl" && return 0

	echo "blkdev_ioctl anchor not found"
	return 1
}

inject_compat_blkdev_ioctl_compat() {
	file="$1"

	inject_ioctl_after_declarations "$file" "compat_blkdev_ioctl" && return 0
	inject_ioctl_after_ret_and_bdev "$file" "compat_blkdev_ioctl" && return 0

	echo "compat_blkdev_ioctl anchor not found"
	return 1
}

inject_ioctl_after_ret_and_bdev() {
	file="$1"
	name="$2"
	xg_tmp="${file}.xg-ddk.tmp"

	awk -v name="$name" '
		BEGIN { in_func=0; saw_ret=0; saw_bdev=0; inserted=0 }
		!in_func && $0 ~ "^[[:space:]]*([_[:alnum:]]+[[:space:]*]+)+" name "[[:space:]]*\\(" {
			in_func=1
			saw_ret=0
			saw_bdev=0
		}
		{
			if (in_func) {
				if ($0 ~ /^[[:space:]]*int[[:space:]]+ret[[:space:]]*;/) saw_ret=1
				if ($0 ~ /^[[:space:]]*struct[[:space:]]+block_device[[:space:]]+\*bdev[[:space:]]*=/) saw_bdev=1
				if (!inserted && saw_ret && saw_bdev &&
				    $0 ~ /^[[:space:]]*(switch[[:space:]]*\(cmd\)|ret[[:space:]]*=|if[[:space:]]*\(|return[[:space:]])/) {
					print "\tret = xg_ddk_blkdev_ioctl(bdev, cmd);"
					print "\tif (ret)"
					print "\t\treturn ret;"
					inserted=1
				}
				if ($0 ~ /^}/) in_func=0
			}
			print
		}
		END { exit inserted ? 0 : 1 }
	' "$file" > "$xg_tmp" && mv "$xg_tmp" "$file" && return 0

	rm -f "$xg_tmp"
	return 1
}

apply_ddk_0030_compat() {
	ioctl_file="$COMMON_ROOT/block/ioctl.c"
	blk_lib_file="$COMMON_ROOT/block/blk-lib.c"

	ensure_ddk_include "$ioctl_file" || return 1
	ensure_ddk_include "$blk_lib_file" || return 1

	if ! function_has_call_name "$ioctl_file" "blkdev_ioctl" "xg_ddk_blkdev_ioctl(bdev, cmd)"; then
		inject_blkdev_ioctl_compat "$ioctl_file" || return 1
	fi

	if ! function_has_call_name "$ioctl_file" "compat_blkdev_ioctl" "xg_ddk_blkdev_ioctl(bdev, cmd)"; then
		inject_compat_blkdev_ioctl_compat "$ioctl_file" || return 1
	fi

	if ! function_has_call_name "$blk_lib_file" "__blkdev_issue_discard" "xg_ddk_blkdev_issue_discard(bdev, sector, nr_sects)"; then
		inject_function_entry_guard \
			"$blk_lib_file" "__blkdev_issue_discard" \
			"xg_ddk_blkdev_issue_discard(bdev, sector, nr_sects)" \
			"xg_ddk_blkdev_issue_discard(bdev, sector, nr_sects)" || return 1
	fi

	if ! function_has_call_name "$blk_lib_file" "__blkdev_issue_zeroout" "xg_ddk_blkdev_issue_zeroout(bdev, sector, nr_sects)"; then
		inject_function_entry_guard \
			"$blk_lib_file" "__blkdev_issue_zeroout" \
			"xg_ddk_blkdev_issue_zeroout(bdev, sector, nr_sects)" \
			"xg_ddk_blkdev_issue_zeroout(bdev, sector, nr_sects)" || return 1
	fi

	if ! function_has_call_name "$blk_lib_file" "blkdev_issue_zeroout" "xg_ddk_blkdev_issue_zeroout(bdev, sector, nr_sects)"; then
		inject_function_entry_guard \
			"$blk_lib_file" "blkdev_issue_zeroout" \
			"xg_ddk_blkdev_issue_zeroout(bdev, sector, nr_sects)" \
			"xg_ddk_blkdev_issue_zeroout(bdev, sector, nr_sects)" || return 1
	fi

	function_has_call_name "$ioctl_file" "blkdev_ioctl" "xg_ddk_blkdev_ioctl(bdev, cmd)" || return 1
	function_has_call_name "$ioctl_file" "compat_blkdev_ioctl" "xg_ddk_blkdev_ioctl(bdev, cmd)" || return 1
	function_has_call_name "$blk_lib_file" "__blkdev_issue_discard" "xg_ddk_blkdev_issue_discard(bdev, sector, nr_sects)" || return 1
	function_has_call_name "$blk_lib_file" "__blkdev_issue_zeroout" "xg_ddk_blkdev_issue_zeroout(bdev, sector, nr_sects)" || return 1
	function_has_call_name "$blk_lib_file" "blkdev_issue_zeroout" "xg_ddk_blkdev_issue_zeroout(bdev, sector, nr_sects)" || return 1
}

apply_ddk_0040_compat() {
	dm_table_file="$COMMON_ROOT/drivers/md/dm-table.c"

	ensure_ddk_include_after_includes "$dm_table_file" || return 1

	if function_has_call_name "$dm_table_file" "dm_table_add_target" "xg_ddk_dm_target_add("; then
		return 0
	fi

	python3 - "$dm_table_file" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    lines = f.readlines()

sig_re = re.compile(r"^\s*int\s+dm_table_add_target\s*\(")
brace_line = None
i = 0
while i < len(lines):
    if sig_re.search(lines[i]):
        j = i
        while j < len(lines):
            if ";" in lines[j] and "{" not in lines[j]:
                break
            if "{" in lines[j]:
                brace_line = j
                break
            j += 1
        if brace_line is not None:
            break
        i = j
    i += 1

if brace_line is None:
    raise SystemExit("dm_table_add_target anchor not found")

depth = 0
end_line = None
for i in range(brace_line, len(lines)):
    depth += lines[i].count("{") - lines[i].count("}")
    if i > brace_line and depth == 0:
        end_line = i + 1
        break

if end_line is None:
    raise SystemExit("dm_table_add_target body end not found")

body = "".join(lines[brace_line:end_line])
if "xg_ddk_dm_target_add(" in body:
    raise SystemExit(0)

for i in range(brace_line, end_line):
    line = lines[i]
    if "t->highs[t->num_targets++]" not in line:
        continue
    match = re.search(r"([A-Za-z_]\w*)->begin\s*\+\s*\1->len\s*-\s*1", line)
    if not match:
        match = re.search(r"([A-Za-z_]\w*)->begin", line)
    if not match:
        continue
    target_var = match.group(1)
    lines.insert(i + 1, f"\n\txg_ddk_dm_target_add({target_var}->type->name);\n")
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    raise SystemExit(0)

raise SystemExit("dm_table_add_target highs anchor not found")
PY

	function_has_call_name "$dm_table_file" "dm_table_add_target" "xg_ddk_dm_target_add(" || return 1
}

echo "[+] Setting up Xingguang DDK LSM"

if [ -d "$PATCH_DIR" ]; then
	echo "[+] Applying Xingguang DDK patch stack"
	for patch in "$PATCH_DIR"/*.patch; do
		[ -e "$patch" ] || continue
		patch_name="$(basename "$patch")"
		optional=false
		case "$patch_name" in
			*.optional.patch) optional=true ;;
		esac
		if git -C "$COMMON_ROOT" apply --check "$patch" >/dev/null 2>&1; then
			git -C "$COMMON_ROOT" apply "$patch"
			echo " - applied $patch_name"
		elif git -C "$COMMON_ROOT" apply --reverse --check "$patch" >/dev/null 2>&1; then
			echo " - already applied $patch_name"
		elif [ "$patch_name" = "0010-vfs-write-callsite.patch" ] && apply_ddk_0010_compat; then
			echo " - applied $patch_name (compat)"
		elif [ "$patch_name" = "0030-block-ioctl-erase-callsite.patch" ] && apply_ddk_0030_compat; then
			echo " - applied $patch_name (compat)"
		elif [ "$patch_name" = "0040-dm-target-callsite.patch" ] && apply_ddk_0040_compat; then
			echo " - applied $patch_name (compat)"
		elif [ "$optional" = true ]; then
			echo " - skipped optional $patch_name"
		else
			echo "[ERROR] failed to apply DDK patch: $patch"
			git -C "$COMMON_ROOT" apply --check "$patch"
			exit 1
		fi
	done
fi

rm -rf "$DDK_DIR"
mkdir -p "$DDK_DIR"
cp -a "$SRC_DIR/." "$DDK_DIR/"

cd "$SECURITY_DIR"
if command -v realpath >/dev/null 2>&1; then
	rel="$(realpath --relative-to="$SECURITY_DIR" "$DDK_DIR" 2>/dev/null || true)"
else
	rel="$DDK_DIR"
fi
[ -n "$rel" ] || rel="$DDK_DIR"
ln -sfn "$rel" "$DDK_SYMLINK"

if ! grep -q 'xingguang-ddk' "$SECURITY_MAKEFILE"; then
	printf '\nobj-$(CONFIG_XINGGUANG_DDK) += xingguang-ddk/\n' >> "$SECURITY_MAKEFILE"
	echo " - Makefile updated"
fi

if ! grep -q 'security/xingguang-ddk/Kconfig' "$SECURITY_KCONFIG"; then
	if grep -n '^endmenu[[:space:]]*$' "$SECURITY_KCONFIG" >/dev/null 2>&1; then
		awk '
			{ a[NR]=$0 }
			END {
				last=0
				for (i=1; i<=NR; i++) if (a[i] ~ /^endmenu[[:space:]]*$/) last=i
				for (i=1; i<=NR; i++) {
					if (i==last) print "source \"security/xingguang-ddk/Kconfig\""
					print a[i]
				}
			}
		' "$SECURITY_KCONFIG" > "$SECURITY_KCONFIG.tmp" && mv "$SECURITY_KCONFIG.tmp" "$SECURITY_KCONFIG"
	else
		printf '\nsource "security/xingguang-ddk/Kconfig"\n' >> "$SECURITY_KCONFIG"
	fi
	echo " - Kconfig updated"
fi

sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /xingguang_ddk/! s/selinux/selinux,xingguang_ddk/ } }' "$SECURITY_KCONFIG"

echo "[+] Xingguang DDK LSM ready."
