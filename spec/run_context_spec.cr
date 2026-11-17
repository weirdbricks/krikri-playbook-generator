require "./spec_helper"
require "../src/krikri_playbook_generator/run_context"

module KrikriPlaybookGenerator
  describe HostInventory do
    it "renders the play group plus delegate-only aliases outside it" do
      assert_equal("target2 ansible_connection=local\ntarget3 ansible_connection=local\n" \
                   "\n[kpg_targets]\ntarget ansible_connection=local\n",
        HostInventory.render(1))
      assert_equal("target3 ansible_connection=local\n\n[kpg_targets]\n" \
                   "target ansible_connection=local\ntarget2 ansible_connection=local\n",
        HostInventory.render(2))
      assert_equal("\n[kpg_targets]\ntarget ansible_connection=local\n" \
                   "target2 ansible_connection=local\ntarget3 ansible_connection=local\n",
        HostInventory.render(3))
      assert_equal(%w[target target2 target3], HostInventory.aliases(3))
      assert_equal("kpg_targets", HostInventory::GROUP)
    end

    it "caps the axis at three aliases" do
      assert_equal(3, HostInventory::MAX_HOSTS)
    end
  end
end
