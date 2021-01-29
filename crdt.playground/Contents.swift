import Cocoa
import Foundation
import XCTest

class Replica<T: Hashable, K: Hashable> {
  typealias Key = T
  typealias Value = K
  typealias DictValue = [Value: TimeInterval]
  var addTimestamp = [Key: DictValue]()
  var removeTimestamp = [Key: TimeInterval]() // removal does not need to care about data's value
  
  func add(key: Key, value: Value, timestamp: TimeInterval = Date().timeIntervalSince1970) {
    let dictValue = [value: timestamp]
    addTimestamp.updateValue(dictValue, forKey: key)
  }
  
  func remove(key: Key, timestamp: TimeInterval = Date().timeIntervalSince1970) {
    removeTimestamp.updateValue(timestamp, forKey: key)
  }
  
  func lookup(key: Key) -> Value? {
    /// An element is a member of the LWW-Element-Set if it is in the add set and not in the remove set
    if let addDictValue = addTimestamp[key],
      let keyValue = addDictValue.keys.first,
      removeTimestamp[key] == nil {
      return keyValue
    }
    
    /// An element is a member of the LWW-Element-Set if it is in the add set or
    /// in the remove set but with an earlier timestamp than the latest timestamp in the add set
    if let addedTimeStamp = addTimestamp[key]?.values.first,
      let removedTimestamp = removeTimestamp[key],
      addedTimeStamp >= removedTimestamp,
      let keyValue = addTimestamp[key]?.keys.first {
      return keyValue
    }
    
    return nil
  }
  
  func update(key: T, value: K, timestamp: TimeInterval = Date().timeIntervalSince1970) {
    if let _ = addTimestamp[key], removeTimestamp[key] == nil {
      add(key: key, value: value, timestamp: timestamp)
      return
    }
  }
  
  func merge(newReplica: Replica) {
    /// merge remove dictionary
    let newRemoveDictionary = newReplica.removeTimestamp
    removeTimestamp = removeTimestamp.merging(newRemoveDictionary) { (currentTimestamp, nextTimestamp) -> TimeInterval in
      if currentTimestamp > nextTimestamp {
        return currentTimestamp
      } else {
        return nextTimestamp
      }
    }
    
    /// merge add dictionary
    let newAddDictionary = newReplica.addTimestamp
    addTimestamp = addTimestamp.merging(newAddDictionary) { (current, next) -> [K : TimeInterval] in
      if let currentTimestamp = current.values.first,
        let nextTimestamp = next.values.first,
        currentTimestamp > nextTimestamp {
        return current
      } else {
        return next
      }
    }
  }
}

// MARK: Unit Tests
/// Definition of Idempotence, Associativity, Commutative taken from http://book.mixu.net/distsys/eventual.html
class CRDTTestSuite: XCTestCase {
  let testKey = "key1"
  let testValue = 20
  
  let testKey2 = "key2"
  let testValue2 = 33
  
  override func setUp() {
    super.setUp()
  }
  
  /// Testing for Idempotence, (add+add=add), where duplication does not matter
  func testAdditionToReplica() {
    let r = Replica<String, Int>()
    r.add(key: testKey, value: testValue)
    let result = r.lookup(key: testKey)
    XCTAssertEqual(result, testValue, "Expect element to be added to addTimestamp dictionary")
    
    r.add(key: testKey, value: testValue, timestamp: 10.00)
    XCTAssertEqual(r.addTimestamp[testKey]?[testValue], 10.00,
                   "Expect that duplicated key should result in just one element in addTimestamp dictionary with latest timestamp")
    
  }
  
  /// Testing for Associative (add+(update+remove)=(add+update)+remove), where grouping doesn't matter
  func testRemovingFromReplica() {
    let r1 = Replica<String, Int>()
    let r2 = Replica<String, Int>()
    r1.add(key: testKey, value: testValue, timestamp: 10.00)
    r1.update(key: testKey, value: 33, timestamp: 11.00)
    r2.remove(key: testKey, timestamp: 12.00)
    
    r2.add(key: testKey2, value: testValue2, timestamp: 10.00)
    r2.update(key: testKey2, value: 44, timestamp: 11.00)
    r1.remove(key: testKey2, timestamp: 12.0)
    
    r1.merge(newReplica: r2)
    
    let lookupResultTestKey = r1.lookup(key: testKey)
    XCTAssertNil(lookupResultTestKey, "Expect lookup to return nil")
    XCTAssertNotNil(r1.addTimestamp[testKey], "Expect that the key-value data is still in the addTimestamp dictionary")
    
    let lookupResultTestKey2 = r1.lookup(key: testKey2)
    XCTAssertNil(lookupResultTestKey2, "Expect lookup to return nil")
    XCTAssertNotNil(r1.addTimestamp[testKey2], "Expect that the key-value data is still in the addTimestamp dictionary")
  }
  
  func testUpdatingToReplica_whenKeyIsNonExistent() {
    let r = Replica<String, Int>()
    r.update(key: "unaddedKey", value: 11)
    let lookupResult = r.lookup(key: "unaddedKey")
    XCTAssertNil(lookupResult, "Expect lookup to return nil as items not added cannot be updated")
  }
  
  func testUpdatingToReplica_whenKeyIsExistent() {
    let r = Replica<String, Int>()
    r.add(key: testKey, value: testValue)
    let addResult = r.lookup(key: testKey)
    XCTAssertEqual(addResult, testValue, "Expect testValue added to addTimestamp dictionary")
    
    let newTestValue = 11
    r.update(key: testKey, value: newTestValue)
    let lookupResult = r.lookup(key: testKey)
    XCTAssertEqual(lookupResult, newTestValue,"Expect lookup to return newTestValue in the same key")
  }
  
  func testMergingReplica_RetainValueWithLatestTimeStamp() {
    let r1 = Replica<String, Int>()
    r1.add(key: testKey, value: testValue, timestamp: 10.00)
    r1.add(key: testKey2, value: testValue2, timestamp: 11.00)
    
    let r2 = Replica<String, Int>()
    r2.add(key: testKey, value: 33, timestamp: 13.00)
    
    r1.merge(newReplica: r2)
    XCTAssertEqual(r1.addTimestamp.count, 2, "Expect only 2 elements after merging")
    
    let lookupTestKey = r1.lookup(key: testKey)
    XCTAssertEqual(lookupTestKey, 33, "Expect testKey to contain value with latest timestamp after merging")
  }
  
  /// Testing for Commutativity (add+remove=remove+add), where order of application doesn't matter.
  func testMergingReplica_RetainValueAdditionBias_TimestampConflicts() {
    let r1 = Replica<String, Int>()
    let r2 = Replica<String, Int>()
    
    r1.add(key: testKey, value: testValue, timestamp: 10.00)
    r2.remove(key: testKey, timestamp: 10.00)
    
    r1.remove(key: testKey2, timestamp: 15.00)
    r2.add(key: testKey2, value: testValue2, timestamp: 15.0)
    
    r1.merge(newReplica: r2)
    
    let lookupTestKey1 = r1.lookup(key: testKey)
    XCTAssertEqual(lookupTestKey1, testValue,
                   "Expect that lookup testKey still succeeds even if conflict of add/remove occurs after merging")
    
    let lookupTestKey2 = r1.lookup(key: testKey2)
    XCTAssertEqual(lookupTestKey2, testValue2,
                   "Expect that lookup testKey2 still succeeds even if conflict of add/remove occurs after merging")
  }
}

CRDTTestSuite.defaultTestSuite.run()

