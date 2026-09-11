//
//  DataSet.swift
//  AIToolbox
//
//  Created by Kevin Coble on 12/6/15.
//  Copyright © 2015 Kevin Coble. All rights reserved.
//

import Foundation

public enum DataSetType: BaseModel   //  data type
{
    case Regression
    case Classification
}

enum DataTypeError: Error {
    case InvalidDataType
    case DataWrongForType
    case WrongDimensionOnInput
    case WrongDimensionOnOutput
}

enum DataIndexError: Error {
    case Negative
    case IndexAboveDimension
    case IndexAboveDataSetSize
}

public struct DataSet: BaseModel {
    /// Sliding-window cap for the regression training path. Oldest points are
    /// evicted once the dataset exceeds this size, keeping GBT training O(1)
    /// in wall-clock time regardless of how long the server has been running.
    static let maxSize = 200

    let dataType : DataSetType
    let inputDimension: Int
    let outputDimension: Int
    var inputs: [[Double]]
    var outputs: [[Double]]?
    var classes: [Int]?
    var labels: [String] = []
    public init(dataType : DataSetType, inputDimension : Int, outputDimension : Int)
    {
        //  Remember the data parameters
        self.dataType = dataType
        self.inputDimension = inputDimension
        self.outputDimension = outputDimension
        
        //  Allocate data arrays
        inputs = []
        if (dataType == .Regression) {
            outputs = []
        }
        else {
            classes = []
        }
    }
    
    public init?(fromDataSet: DataSet, withEntries: [Int])
    {
        //  Remember the data parameters
        self.dataType = fromDataSet.dataType
        self.inputDimension = fromDataSet.inputDimension
        self.outputDimension = fromDataSet.outputDimension
        
        //  Allocate data arrays
        inputs = []
        if (dataType == .Regression) {
            outputs = []
        }
        else {
            classes = []
        }
        
        //  Copy the entries
        do {
            try includeEntries(fromDataSet: fromDataSet, withEntries: withEntries)
        }
        catch {
            return nil
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case dataType
        case inputDimension
        case outputDimension
        case inputs
        case outputs
        case classes
        case labels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let dataType: DataSetType = try container.decodeIfPresent(DataSetType.self, forKey: .dataType) ?? .Regression
        let inDim: Int = try container.decode(Int.self, forKey: .inputDimension)
        let outDim: Int = try container.decode(Int.self, forKey: .outputDimension)
        let inputs: [[Double]] = try container.decode([[Double]].self, forKey: .inputs)
        let outputs: [[Double]]? = try container.decodeIfPresent([[Double]].self, forKey: .outputs)
        let classes: [Int]? = try container.decodeIfPresent([Int].self, forKey: .classes)
        let labels: [String] = try container.decode([String].self, forKey: .labels)

        self.dataType = dataType
        self.inputDimension = inDim
        self.outputDimension = outDim
        self.inputs = inputs
        self.outputs = outputs
        self.classes = classes
        self.labels = labels
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(dataType, forKey: .dataType)
        try container.encode(inputDimension, forKey: .inputDimension)
        try container.encode(outputDimension, forKey: .outputDimension)
        try container.encode(inputs, forKey: .inputs)
        try container.encodeIfPresent(outputs, forKey: .outputs)
        try container.encodeIfPresent(classes, forKey: .classes)
        try container.encode(labels, forKey: .labels)
    }
    
    public mutating func includeEntries(fromDataSet: DataSet, withEntries: [Int]) throws
    {
        //  Make sure the dataset matches
        if dataType != fromDataSet.dataType { throw DataTypeError.InvalidDataType }
        if inputDimension != fromDataSet.inputDimension { throw DataTypeError.WrongDimensionOnInput }
        if outputDimension != fromDataSet.outputDimension { throw DataTypeError.WrongDimensionOnOutput }
        
        //  Copy the entries
        for index in withEntries {
            if (index  < 0) { throw DataIndexError.Negative }
            if (index  >= fromDataSet.size) { throw DataIndexError.IndexAboveDataSetSize }
            inputs.append(fromDataSet.inputs[index])
            if (dataType == .Regression) {
                outputs!.append(fromDataSet.outputs![index])
            }
            else {
                classes!.append(fromDataSet.classes![index])
                if outputs != nil {
                    outputs!.append(fromDataSet.outputs![index])
                }
            }
        }
    }
    
    public var size: Int
    {
        return inputs.count
    }
    
    public func singleOutput(index: Int) -> Double?
    {
        //  Validate the index
        if (index < 0) { return nil}
        if (index >= inputs.count) { return nil }
        
        //  Get the data
        if (dataType == .Regression) {
            return outputs![index][0]
        }
        else {
            return Double(classes![index])
        }
    }
    
    public mutating func addDataPoint(input : [Double], output: [Double], label: String = "unknown") throws
    {
        //  Validate the data
        if (dataType != .Regression) { throw DataTypeError.DataWrongForType }
        if (input.count != inputDimension) { throw DataTypeError.WrongDimensionOnInput }
        if (output.count != outputDimension) { throw DataTypeError.WrongDimensionOnOutput }

        //  Add the new data item
        inputs.append(input)
        outputs!.append(output)
        self.labels.append(label)

        // Sliding window: evict oldest points once the cap is reached so GBT
        // training cost stays bounded regardless of server uptime.
        if inputs.count > DataSet.maxSize {
            let excess = inputs.count - DataSet.maxSize
            inputs.removeFirst(excess)
            outputs!.removeFirst(excess)
            labels = Array(labels.dropFirst(excess))
        }
    }
    
    public mutating func addDataPoint(input : [Double], output: Int) throws
    {
        //  Validate the data
        if (dataType != .Classification) { throw DataTypeError.DataWrongForType }
        if (input.count != inputDimension) { throw DataTypeError.WrongDimensionOnInput }
        
        //  Add the new data item
        inputs.append(input)
        classes!.append(output)
    }
    
    public mutating func setClass(index: Int, newClass : Int) throws
    {
        //  Validate the data
        if (dataType != .Classification) { throw DataTypeError.DataWrongForType }
        if (index < 0) { throw  DataIndexError.Negative }
        if (index > inputs.count) { throw  DataIndexError.Negative }
        
        classes![index] = newClass
    }
    
    public mutating func addTestDataPoint(input : [Double]) throws
    {
        //  Validate the data
        if (input.count != inputDimension) { throw DataTypeError.WrongDimensionOnInput }
        
        //  Add the new data item
        inputs.append(input)
    }
    
    public func getClass(index: Int) throws ->Int
    {
        //  Validate the data
        if (dataType != .Classification) { throw DataTypeError.DataWrongForType }
        if (index < 0) { throw  DataIndexError.Negative }
        if (index > inputs.count) { throw  DataIndexError.Negative }
        
        return classes![index]
    }
    
    /// Prunes the dataset to keep only the data points at the given indices.
    /// Indices must be valid and are deduplicated + sorted internally.
    /// Used after SVM training to retain support vectors + a recent buffer.
    public mutating func pruneKeeping(indices: Set<Int>) {
        let sorted = indices.sorted()
        inputs = sorted.map { inputs[$0] }
        if dataType == .Regression {
            if let out = outputs {
                outputs = sorted.map { out[$0] }
            }
        } else {
            if let cls = classes {
                classes = sorted.map { cls[$0] }
            }
        }
        if !labels.isEmpty {
            let oldLabels = labels
            labels = sorted.map { oldLabels[$0] }
        }
    }

    public func getRandomIndexSet() -> [Int]
    {
        //  Get the ordered array of indices
        let orderedArray = Array(0..<inputs.count)
        
        // Use shuffled() which is cross-platform and available since Swift 4.2
        return orderedArray.shuffled()
    }
}
