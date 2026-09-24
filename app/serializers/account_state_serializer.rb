# The account payload. Identical in shape to a historical snapshot, so both
# render through the same fields and a client cannot tell them apart.
class AccountStateSerializer < AccountSnapshotSerializer
end
