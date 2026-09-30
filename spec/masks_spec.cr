require "./spec_helper"
require "../src/krikri_playbook_generator/masks"

module KrikriPlaybookGenerator
  describe ByteDiff do
    it "masks the real ansible discovered-Python WARNING line on both sides" do
      text = "PLAY [x]\n[WARNING]: Host 'target' is using the discovered Python interpreter at /usr/bin/python3.12, but future installation of another Python interpreter could change this.\nok: done\n"
      masked = ByteDiff.mask(text)
      refute(masked.includes?("discovered Python interpreter"))
      assert(masked.includes?("PLAY [x]"))
      assert(masked.includes?("ok: done"))
    end

    it "masks only the lone discovered_interpreter_python key in a fatal JSON dump" do
      with_key = %(fatal: [t]: FAILED! => {"ansible_facts": {"discovered_interpreter_python": "/usr/bin/python3.13"}, "changed": false, "msg": "x"}\n)
      without = %(fatal: [t]: FAILED! => {"changed": false, "msg": "x"}\n)
      assert_equal(ByteDiff.mask(without), ByteDiff.mask(with_key))

      other = %(fatal: [t]: FAILED! => {"ansible_facts": {"other": 1}, "changed": false}\n)
      assert(ByteDiff.mask(other).includes?(%("ansible_facts": {"other": 1})))
    end

    it "masks the 8 random characters of a tempfile mkstemp name, and nothing else" do
      a = %(msg: [Errno 2] No such file or directory: '/work/78/ansible.qgfgwzyx.txt'\n)
      b = %(msg: [Errno 2] No such file or directory: '/work/78/ansible.abc12_09.txt'\n)
      assert_equal(ByteDiff.mask(a), ByteDiff.mask(b))

      # a different directory, prefix or suffix must still differ
      other_suffix = %(msg: [Errno 2] No such file or directory: '/work/78/ansible.qgfgwzyx.cfg'\n)
      refute_equal(ByteDiff.mask(a), ByteDiff.mask(other_suffix))
      custom_prefix = %(msg: [Errno 2] No such file or directory: '/work/78/pre_qgfgwzyx.txt'\n)
      # a custom prefix is deterministic and stays; only the random 8 chars go
      assert(ByteDiff.mask(custom_prefix).includes?("pre_<RND>.txt"))
    end

    it "sorts the invalid-option list of include_role (random Python set order in real)" do
      a = %(msg: Invalid options for ansible.builtin.include_role: vars_from_bogus,apply_bogus,name_bogus\n)
      b = %(msg: Invalid options for ansible.builtin.include_role: apply_bogus,name_bogus,vars_from_bogus\n)
      assert_equal(ByteDiff.mask(a), ByteDiff.mask(b))
      # different membership must still differ
      c = %(msg: Invalid options for ansible.builtin.include_role: apply_bogus,name_bogus\n)
      refute_equal(ByteDiff.mask(a), ByteDiff.mask(c))
    end

    it "masks the random mkstemp characters of a custom-prefix tempfile name" do
      a = %(msg: [Errno 2] No such file or directory: '77/tmp_f673j131.txt'\n)
      b = %(msg: [Errno 2] No such file or directory: '77/tmp_52amfxwl.txt'\n)
      assert_equal(ByteDiff.mask(a), ByteDiff.mask(b))
      refute_equal(ByteDiff.mask(a), ByteDiff.mask(b.sub("77/", "/work/77/")))
      refute_equal(ByteDiff.mask(a), ByteDiff.mask(a.sub("tmp_", "pre_")))
    end

    it "masks the random mkstemp characters after a numeric or empty prefix" do
      a = %(msg: [Errno 2] No such file or directory: '/work/30/92li3lyz4e.txt'\n)
      b = %(msg: [Errno 2] No such file or directory: '/work/30/92ka3ewei0.txt'\n)
      assert_equal(ByteDiff.mask(a), ByteDiff.mask(b))
      refute_equal(ByteDiff.mask(a), ByteDiff.mask(b.sub("92", "93")))
      refute_equal(ByteDiff.mask(a), ByteDiff.mask(b.sub("/30/", "/31/")))
    end

    it "masks which wrong-typed string option include_role reports first (random set order)" do
      a = %([ERROR]: Expected a string for tasks_from but got <class 'x'> instead\n)
      b = %([ERROR]: Expected a string for vars_from but got <class 'x'> instead\n)
      assert_equal(ByteDiff.mask(a), ByteDiff.mask(b))
      refute_equal(ByteDiff.mask(a), ByteDiff.mask(a.sub("'x'", "'y'")))
    end

    it "masks the per-process set order of convert_bool's valid-boolean list" do
      a = %(msg: The value 'x' is not a valid boolean. Valid booleans include: 0, '1', 'on', 1, 'yes'\n)
      b = %(msg: The value 'x' is not a valid boolean. Valid booleans include: 'yes', 1, 0, 'on', '1'\n)
      assert_equal(ByteDiff.mask(a), ByteDiff.mask(b))
      refute_equal(ByteDiff.mask(a), ByteDiff.mask(a.sub("boolean. Valid", "boolean.  Valid")))
    end

    it "masks ansible temp dir names and timestamps identically" do
      a = "Using module file /root/.ansible/tmp/ansible-tmp-1727612345.123456-123456789012345/AnsiballZ_copy.py\n"
      b = "Using module file /root/.ansible/tmp/ansible-tmp-1727699999.999999-987654321098765/AnsiballZ_copy.py\n"
      assert_equal(ByteDiff.mask(a), ByteDiff.mask(b))

      stamped_a = "backup saved as /tmp/kpg-work/out1.txt.4242.2026-09-29@12:00:00.123456~\n"
      stamped_b = "backup saved as /tmp/kpg-work/out1.txt.7777.2030-01-01@03:04:05.6~\n"
      assert_equal(ByteDiff.mask(stamped_a), ByteDiff.mask(stamped_b))
    end

    it "does not mask short numbers that carry real meaning" do
      text = "rc=2 changed=1 port=22\n"
      assert_equal(text, ByteDiff.mask(text))
    end

    it "produces an empty diff for identical text and +/- lines for differences" do
      assert_equal("", ByteDiff.unified("same\nlines\n", "same\nlines\n"))

      diff = ByteDiff.unified("ok: [target]\n", "failed: [target]\n")
      assert(diff.includes?("-ok: [target]\n"))
      assert(diff.includes?("+failed: [target]\n"))
    end

    it "gives two playbooks with the same root cause the same signature" do
      diff_a = ByteDiff.unified("fatal: [target]: mode 387 is invalid (must be octal)\n",
        "fatal: [target]: mode 711 is invalid (must be octal)\n")
      diff_b = ByteDiff.unified("fatal: [target]: mode 100 is invalid (must be octal)\n",
        "fatal: [target]: mode 999 is invalid (must be octal)\n")

      sig_a = ByteDiff.signature(diff_a)
      sig_b = ByteDiff.signature(diff_b)
      refute_nil(sig_a)
      assert_equal(sig_a, sig_b)
    end

    it "returns nil for a signature when there are no changed lines" do
      assert_nil(ByteDiff.signature(" stdout\n"))
    end
  end
end
