import unittest
from pathlib import Path


class WorkflowConfigTests(unittest.TestCase):
    def test_push_workflow_uses_destination_owner_variable(self):
        workflow = Path(".github/workflows/5_push_to_github_account.yml").read_text()

        self.assertIn("ACTE_TARGET_GITHUB_OWNER: ${{ vars.ACTE_TARGET_GITHUB_OWNER }}", workflow)
        self.assertIn('expected_owner="$ACTE_TARGET_GITHUB_OWNER"', workflow)
        self.assertIn('--expected-owner "$expected_owner"', workflow)

    def test_push_workflow_does_not_default_to_bootstrap_owner(self):
        workflow = Path(".github/workflows/5_push_to_github_account.yml").read_text()

        self.assertNotIn("Ms01Ar5uo0sXa59GnodsE81s0paiN", workflow)


if __name__ == "__main__":
    unittest.main()
