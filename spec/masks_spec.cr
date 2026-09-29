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
