require "./spec_helper"
require "../src/krikri_playbook_generator/table"

module KrikriPlaybookGenerator
  describe Table do
    it "pads every column to its widest cell and draws the header separator" do
      text = Table.render(["module", "n"], [["copy", "2"], ["postgresql_privs", "12"]])

      assert_equal(<<-TABLE.rstrip, text)
┌──────────────────┬────┐
│ module           │ n  │
├──────────────────┼────┤
│ copy             │ 2  │
│ postgresql_privs │ 12 │
└──────────────────┴────┘
TABLE
    end

    it "right-aligns only the named columns, headers stay left-aligned" do
      text = Table.render(["run", "module", "# of playbooks"],
        [["1", "copy", "2"], ["12", "apt", "10"]], right_align: ["run", "# of playbooks"])

      assert_equal(<<-TABLE.rstrip, text)
┌─────┬────────┬────────────────┐
│ run │ module │ # of playbooks │
├─────┼────────┼────────────────┤
│   1 │ copy   │              2 │
│  12 │ apt    │             10 │
└─────┴────────┴────────────────┘
TABLE
    end

    it "keeps a short row aligned by padding missing trailing cells" do
      text = Table.render(["a", "b"], [["x"]])

      assert_equal(<<-TABLE.rstrip, text)
┌───┬───┐
│ a │ b │
├───┼───┤
│ x │   │
└───┴───┘
TABLE
    end
  end
end
