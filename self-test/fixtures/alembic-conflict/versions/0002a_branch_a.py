"""branch a

Orbit self-test fixture — one of two competing heads (RED case for
alembic-single-head.yml, combined with 0002b_branch_b.py).
"""

revision = "0002a"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade():
    pass


def downgrade():
    pass
