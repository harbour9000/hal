# test_bpm_engine

- [x] receive ok
- [x] auto path reaches approved
- [x] auto path has nothing pending
- [x] auto_approve executed by cascade
- [x] auto handler ran
- [x] history: receive + auto_approve
- [x] manual path waits in received
- [x] manual_approve pending
- [x] manual approve refused without role
- [x] manual approve with role
- [x] manual handler ran with user
- [x] pending cleared after manual approve
- [x] repeated manual approve is a clear no-op error
- [x] receive without fields refused by rule
- [x] second instance independent
- [x] incomplete invoice returned
- [x] supplier notified by handler
- [x] missing id refused
- [x] duplicate instance refused
- [x] unknown action refused
- [x] unknown instance refused
- [x] bad user refused
- [x] bad process refused
- [x] invalid definition refused
- [x] decision with unknown branch refused
- [x] decision loop stopped by guard
- [x] limit rule on receive
- [x] get unknown returns NIL
- [x] history unknown returns empty
- [x] F-2 history: receive + route + manual_approve

**PASS**
