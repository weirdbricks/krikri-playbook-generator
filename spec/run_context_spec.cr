require "./spec_helper"
require "../src/krikri_playbook_generator/run_context"

module KrikriPlaybookGenerator
  describe HostInventory do
    it "renders one local alias per host, keeping target as the first" do
      assert_equal("target ansible_connection=local\n", HostInventory.render(1))
      assert_equal("target ansible_connection=local\ntarget2 ansible_connection=local\n",
        HostInventory.render(2))
      assert_equal(%w[target target2 target3], HostInventory.aliases(3))
    end

    it "caps the axis at three aliases" do
      assert_equal(3, HostInventory::MAX_HOSTS)
    end
  end
end
