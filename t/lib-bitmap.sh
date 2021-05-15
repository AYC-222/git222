# Helpers for scripts testing bitamp functionality; see t5310 for
# example usage.

# Compare a file containing rev-list bitmap traversal output to its non-bitmap
# counterpart. You can't just use test_cmp for this, because the two produce
# subtly different output:
#
#   - regular output is in traversal order, whereas bitmap is split by type,
#     with non-packed objects at the end
#
#   - regular output has a space and the pathname appended to non-commit
#     objects; bitmap output omits this
#
# This function normalizes and compares the two. The second file should
# always be the bitmap output.
test_bitmap_traversal () {
	if test "$1" = "--no-confirm-bitmaps"
	then
		shift
	elif cmp "$1" "$2"
	then
		echo >&2 "identical raw outputs; are you sure bitmaps were used?"
		return 1
	fi &&
	cut -d' ' -f1 "$1" | sort >"$1.normalized" &&
	sort "$2" >"$2.normalized" &&
	test_cmp "$1.normalized" "$2.normalized" &&
	rm -f "$1.normalized" "$2.normalized"
}

# To ensure the logic for "maximal commits" is exercised, make
# the repository a bit more complicated.
#
#    other                         second
#      *                             *
# (99 commits)                  (99 commits)
#      *                             *
#      |\                           /|
#      | * octo-other  octo-second * |
#      |/|\_________  ____________/|\|
#      | \          \/  __________/  |
#      |  | ________/\ /             |
#      *  |/          * merge-right  *
#      | _|__________/ \____________ |
#      |/ |                         \|
# (l1) *  * merge-left               * (r1)
#      | / \________________________ |
#      |/                           \|
# (l2) *                             * (r2)
#       \___________________________ |
#                                   \|
#                                    * (base)
#
# We only push bits down the first-parent history, which
# makes some of these commits unimportant!
#
# The important part for the maximal commit algorithm is how
# the bitmasks are extended. Assuming starting bit positions
# for second (bit 0) and other (bit 1), the bitmasks at the
# end should be:
#
#      second: 1       (maximal, selected)
#       other: 01      (maximal, selected)
#      (base): 11 (maximal)
#
# This complicated history was important for a previous
# version of the walk that guarantees never walking a
# commit multiple times. That goal might be important
# again, so preserve this complicated case. For now, this
# test will guarantee that the bitmaps are computed
# correctly, even with the repeat calculations.
setup_bitmap_history() {
	test_expect_success 'setup repo with moderate-sized history' '
		test_commit_bulk --id=file 10 &&
		git branch -M second &&
		git checkout -b other HEAD~5 &&
		test_commit_bulk --id=side 10 &&

		# add complicated history setup, including merges and
		# ambiguous merge-bases

		git checkout -b merge-left other~2 &&
		git merge second~2 -m "merge-left" &&

		git checkout -b merge-right second~1 &&
		git merge other~1 -m "merge-right" &&

		git checkout -b octo-second second &&
		git merge merge-left merge-right -m "octopus-second" &&

		git checkout -b octo-other other &&
		git merge merge-left merge-right -m "octopus-other" &&

		git checkout other &&
		git merge octo-other -m "pull octopus" &&

		git checkout second &&
		git merge octo-second -m "pull octopus" &&

		# Remove these branches so they are not selected
		# as bitmap tips
		git branch -D merge-left &&
		git branch -D merge-right &&
		git branch -D octo-other &&
		git branch -D octo-second &&

		# add padding to make these merges less interesting
		# and avoid having them selected for bitmaps
		test_commit_bulk --id=file 100 &&
		git checkout other &&
		test_commit_bulk --id=side 100 &&
		git checkout second &&

		bitmaptip=$(git rev-parse second) &&
		blob=$(echo tagged-blob | git hash-object -w --stdin) &&
		git tag tagged-blob $blob
	'
}

rev_list_tests_head () {
	test_expect_success "counting commits via bitmap ($state, $branch)" '
		git rev-list --count $branch >expect &&
		git rev-list --use-bitmap-index --count $branch >actual &&
		test_cmp expect actual
	'

	test_expect_success "counting partial commits via bitmap ($state, $branch)" '
		git rev-list --count $branch~5..$branch >expect &&
		git rev-list --use-bitmap-index --count $branch~5..$branch >actual &&
		test_cmp expect actual
	'

	test_expect_success "counting commits with limit ($state, $branch)" '
		git rev-list --count -n 1 $branch >expect &&
		git rev-list --use-bitmap-index --count -n 1 $branch >actual &&
		test_cmp expect actual
	'

	test_expect_success "counting non-linear history ($state, $branch)" '
		git rev-list --count other...second >expect &&
		git rev-list --use-bitmap-index --count other...second >actual &&
		test_cmp expect actual
	'

	test_expect_success "counting commits with limiting ($state, $branch)" '
		git rev-list --count $branch -- 1.t >expect &&
		git rev-list --use-bitmap-index --count $branch -- 1.t >actual &&
		test_cmp expect actual
	'

	test_expect_success "counting objects via bitmap ($state, $branch)" '
		git rev-list --count --objects $branch >expect &&
		git rev-list --use-bitmap-index --count --objects $branch >actual &&
		test_cmp expect actual
	'

	test_expect_success "enumerate commits ($state, $branch)" '
		git rev-list --use-bitmap-index $branch >actual &&
		git rev-list $branch >expect &&
		test_bitmap_traversal --no-confirm-bitmaps expect actual
	'

	test_expect_success "enumerate --objects ($state, $branch)" '
		git rev-list --objects --use-bitmap-index $branch >actual &&
		git rev-list --objects $branch >expect &&
		test_bitmap_traversal expect actual
	'

	test_expect_success "bitmap --objects handles non-commit objects ($state, $branch)" '
		git rev-list --objects --use-bitmap-index $branch tagged-blob >actual &&
		grep $blob actual
	'
}

rev_list_tests () {
	state=$1

	for branch in "second" "other"
	do
		rev_list_tests_head
	done
}

basic_bitmap_tests () {
	tip="$1"
	test_expect_success 'rev-list --test-bitmap verifies bitmaps' "
		git rev-list --test-bitmap "${tip:-HEAD}"
	"

	rev_list_tests 'full bitmap'

	test_expect_success 'clone from bitmapped repository' '
		rm -fr clone.git &&
		git clone --no-local --bare . clone.git &&
		git rev-parse HEAD >expect &&
		git --git-dir=clone.git rev-parse HEAD >actual &&
		test_cmp expect actual
	'

	test_expect_success 'partial clone from bitmapped repository' '
		test_config uploadpack.allowfilter true &&
		rm -fr partial-clone.git &&
		git clone --no-local --bare --filter=blob:none . partial-clone.git &&
		(
			cd partial-clone.git &&
			pack=$(echo objects/pack/*.pack) &&
			git verify-pack -v "$pack" >have &&
			awk "/blob/ { print \$1 }" <have >blobs &&
			# we expect this single blob because of the direct ref
			git rev-parse refs/tags/tagged-blob >expect &&
			test_cmp expect blobs
		)
	'

	test_expect_success 'setup further non-bitmapped commits' '
		test_commit_bulk --id=further 10
	'

	rev_list_tests 'partial bitmap'

	test_expect_success 'fetch (partial bitmap)' '
		git --git-dir=clone.git fetch origin second:second &&
		git rev-parse HEAD >expect &&
		git --git-dir=clone.git rev-parse HEAD >actual &&
		test_cmp expect actual
	'
}

# have_delta <obj> <expected_base>
#
# Note that because this relies on cat-file, it might find _any_ copy of an
# object in the repository. The caller is responsible for making sure
# there's only one (e.g., via "repack -ad", or having just fetched a copy).
have_delta () {
	echo $2 >expect &&
	echo $1 | git cat-file --batch-check="%(deltabase)" >actual &&
	test_cmp expect actual
}

midx_checksum () {
	test-tool read-midx --checksum "${1:-.git/objects}"
}