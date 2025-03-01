# frozen_string_literal: true

require 'connectors/mongodb/connector'
require 'core/filtering/simple_rules/simple_rule'
require 'hashie/mash'
require 'spec_helper'

describe Connectors::MongoDB::Connector do
  subject { described_class.new(configuration: configuration, job_description: job_description) }

  let(:filter_transformers) {
    {
      'rules' => [],
      'advanced_snippet' => []
    }
  }

  let(:configuration) do
    {
      :host => {
        :label => 'Server Hostname',
        :value => mongodb_host
      },
      :database => {
        :label => 'Database',
        :value => mongodb_database
      },
      :collection => {
        :label => 'Collection',
        :value => mongodb_collection
      },
      :user => {
        :label => 'Username',
        :value => mongodb_username
      },
      :password => {
        :label => 'Password',
        :value => mongodb_password
      },
      :direct_connection => {
        :label => 'Direct connection? (true/false)',
        :value => direct_connection
      },
      :filtering => {
        :active => filtering
      }
    }
  end

  let(:rules) do
    [
      {
        'id' => 'test',
        'field' => 'name',
        'rule' => Core::Filtering::SimpleRule::Rule::EQUALS,
        'policy' => Core::Filtering::SimpleRule::Policy::INCLUDE,
        'value' => 'apple'
      }
    ]
  end

  let(:pipeline) {
    [
      {
        :$group” => {
          :_id => { :$dateToString => { :format => '%Y-%m-%d', :date => '$date' } },
          :totalOrderValue => { :$sum => { :$multiply => %w[$price $quantity] } },
          :averageOrderQuantity => { :$avg => '$quantity' }
        }
      }
    ]
  }

  let(:filter) {
    {
      :$text => {
        :$search => 'garden',
        :$caseSensitive => false
      }
    }
  }

  let(:options) {
    {
      :skip => 10,
      :limit => 1000
    }
  }

  let(:find) {
    {
      :filter => filter,
      :options => options
    }
  }

  let(:aggregate) {
    {
      :pipeline => pipeline,
      :options => options
    }
  }

  let(:advanced_snippet) {
    {
      :find => find
    }
  }

  let(:filtering) {
    {
      :rules => rules,
      :advanced_snippet => advanced_snippet
    }
  }

  let(:job_description) { double }

  let(:mongodb_host) { '127.0.0.1:27027' }
  let(:mongodb_database) { 'sample-database' }
  let(:mongodb_collection) { 'sample-collection' }
  let(:mongodb_username) { nil }
  let(:mongodb_password) { nil }
  let(:direct_connection) { 'false' }

  let(:mongo_client) { double }

  let(:actual_collection_name) { 'sample-collection' }
  let(:actual_collection) { double }
  let(:actual_collection_names) { [actual_collection_name] }
  let(:actual_collection_data) { [] }
  let(:mongo_collection_cursor) { double }
  let(:mongo_collection_data) { [] }
  let(:actual_database) { double }
  let(:actual_database_names) { ['sample-database'] }

  before(:each) do
    # transformers are tested in their own specs (multiple transformers and their interaction should be tested here later)
    allow(described_class).to receive(:filter_transformers).and_return(filter_transformers)

    allow(job_description).to receive(:dup).and_return(job_description)
    allow(job_description).to receive(:configuration).and_return(configuration)
    allow(job_description).to receive(:filtering).and_return(filtering)

    allow(Mongo::Client).to receive(:new).and_yield(mongo_client)

    allow(mongo_client).to receive(:collections).and_return([Hashie::Mash.new({ :name => actual_collection_name })])
    allow(mongo_client).to receive(:database).and_return(actual_database)
    allow(mongo_client).to receive(:database_names).and_return(actual_database_names)
    allow(mongo_client).to receive(:[]).with(mongodb_collection).and_return(actual_collection)
    allow(mongo_client).to receive(:with).and_return(mongo_client)
    allow(mongo_client).to receive(:close)

    allow(actual_database).to receive(:collection_names).and_return(actual_collection_names)
    allow(actual_collection).to receive(:find).and_return(mongo_collection_cursor)
    allow(actual_collection).to receive(:aggregate).and_return(mongo_collection_cursor)

    allow(mongo_collection_cursor).to receive(:skip).and_return(mongo_collection_cursor)
    allow(mongo_collection_cursor).to receive(:limit).and_return(mongo_collection_data)
  end

  it_behaves_like 'a connector'

  shared_examples_for 'handles auth' do
    context 'when username and password are provided' do
      let(:mongodb_username) { 'admin' }
      let(:mongodb_password) { 'some-password' }
      it 'sets client to use basic auth' do
        expect(Mongo::Client).to receive(:new).with(anything, hash_including(:user => mongodb_username, :password => mongodb_password))

        do_test
      end
    end

    context 'when no username and password are provided' do
      it 'does not set client to use basic auth' do
        expect(Mongo::Client).to_not receive(:new).with(anything, hash_including(:user => mongodb_username, :password => mongodb_password))

        do_test
      end
    end
  end

  shared_examples_for 'validates direct_connection' do
    %w[true false].each do |value|
      context "when direct_connection is #{value}" do
        let(:direct_connection) { value }

        it 'does not throw error' do
          expect { do_test }.to_not raise_error
        end
      end
    end

    context 'when direct_connection is not a boolean' do
      let(:direct_connection) { 'foobar' }

      it 'throws error' do
        expect { do_test }.to raise_error
      end
    end
  end

  describe '#is_healthy?' do
    it_behaves_like 'handles auth' do
      let(:do_test) { subject.is_healthy? }
    end

    it 'instantiates a mongodb client' do
      expect(Mongo::Client).to receive(:new).with(mongodb_host, hash_including(:database => mongodb_database))

      subject.is_healthy?
    end
  end

  describe '#yield_documents' do
    it_behaves_like 'handles auth' do
      let(:do_test) { subject.yield_documents { |doc|; } }
    end
    it_behaves_like 'validates direct_connection' do
      let(:do_test) { subject.yield_documents { |doc|; } }
    end

    context 'when database is not found' do
      let(:mongodb_database) { 'non-existing-database' }

      it 'does raise' do
        expect { |b| subject.yield_documents(&b) }.to raise_error(anything)
      end
    end

    context 'when collection is not found' do
      let(:mongodb_collection) { 'non-existing-collection' }

      it 'does raise' do
        expect { |b| subject.yield_documents(&b) }.to raise_error(anything)
      end
    end

    context 'when collection is found' do
      context 'when data is distributed in multiple pages' do
        let(:page_size) { 3 }
        let(:doc2) { { '_id' => '2', 'more' => { 'nested' => 'data' } } }

        let(:first_page_data) do
          [
            { '_id' => '1', 'some' => { 'nested' => 'data' } },
            doc2,
            { '_id' => '167', 'nothing' => nil }
          ]
        end

        let(:second_page_data) do
          [
            { '_id' => 'last' }
          ]
        end

        let(:third_page_data) do
          []
        end

        let(:all_data) { first_page_data + second_page_data + third_page_data }

        let(:second_page_cursor) { double }
        let(:third_page_cursor) { double }

        let(:options) {
          nil
        }

        before(:each) do
          stub_const('Connectors::MongoDB::Connector::PAGE_SIZE', page_size)
          allow(mongo_collection_cursor).to receive(:skip).with(0).and_return(mongo_collection_cursor)
          allow(mongo_collection_cursor).to receive(:limit).and_return(first_page_data)

          allow(mongo_collection_cursor).to receive(:skip).with(page_size).and_return(second_page_cursor)
          allow(second_page_cursor).to receive(:limit).and_return(second_page_data)

          allow(mongo_collection_cursor).to receive(:skip).with(page_size * 2).and_return(third_page_cursor)
          allow(third_page_cursor).to receive(:limit).and_return(third_page_data)
        end

        it 'fetches each page' do
          # a bit weird test, but I did not figure out to do a better job ensuring that each page was fetched
          expect(mongo_collection_cursor).to receive(:limit).once
          expect(second_page_cursor).to receive(:limit).once
          expect(third_page_cursor).to receive(:limit).once

          subject.yield_documents { |doc|; }
        end

        it 'yields each document of the collection remapping ids correctly scrolling through pages' do
          expected_ids = all_data.map { |d| d['_id'] }.to_a

          yielded_documents = []

          subject.yield_documents { |doc| yielded_documents << doc }

          expect(yielded_documents.size).to eq(all_data.size)
          expected_ids.each do |id|
            expect(yielded_documents).to include(a_hash_including('id' => id))
          end
        end

        context 'when a single document causes an error' do
          let(:tolerable_error) { 'mock serialization failure' }
          before(:each) do
            allow(subject).to receive(:serialize).and_call_original
            allow(subject).to receive(:serialize).with(doc2).and_raise(tolerable_error)
          end

          it 'does not crash' do
            expect(Utility::Logger).to receive(:warn).with(include(tolerable_error))
            expect { subject.yield_documents { |_| }.to_a }.to_not raise_error
          end
        end

        context 'an overall limit is set' do
          let(:options) {
            {
              :limit => 1
            }
          }

          let(:advanced_snippet) {
            {
              :find => {
                :options => options
              },
            }
          }

          it 'fetches 1 document overall' do
            yielded_documents = []

            subject.yield_documents { |doc| yielded_documents << doc }

            expect(yielded_documents.size).to eq(1)
          end
        end

        context 'skip is set for filtering' do
          let(:options) {
            {
              :skip => 1
            }
          }

          let(:advanced_snippet) {
            {
              :find => {
                :options => options
              },
            }
          }

          before(:each) do
            allow(mongo_collection_cursor).to receive(:skip).with(1).and_return(mongo_collection_cursor)

            # skip first element
            allow(mongo_collection_cursor).to receive(:limit).and_return(first_page_data[1..2])

            # start at page_size + 1 element (skipped element at the beginning)
            allow(mongo_collection_cursor).to receive(:skip).with(page_size + 1).and_return(second_page_cursor)
            allow(second_page_cursor).to receive(:limit).and_return(second_page_data)

            # start at (page_size * 2) + 1 element (skipped element at the beginning)
            allow(mongo_collection_cursor).to receive(:skip).with((page_size * 2) + 1).and_return(third_page_cursor)

            allow(third_page_cursor).to receive(:limit).and_return(third_page_data)
          end

          it 'skips the first element, yielding 3 overall' do
            yielded_documents = []

            subject.yield_documents { |doc| yielded_documents << doc }

            expect(yielded_documents.size).to eq(3)
          end
        end
      end

      context 'when field of type BSON::ObjectId is met' do
        let(:id) { '63238d68dc461bfe327e9634' }

        let(:actual_collection_data) do
          [
            { '_id' => BSON::ObjectId.from_string(id) }
          ]
        end

        it 'serializes the field correctly' do
          # only 1 record is there, so meh no need to do it outside of yield_documents
          subject.yield_documents do |doc|
            expect(doc['id']).to eq(id)
          end
        end
      end

      context 'when field of type BSON::Decimal128 is met' do
        let(:price) { '12.00' }

        let(:actual_collection_data) do
          [
            { '_id' => 1, 'price' => BSON::Decimal128.from_string(price) }
          ]
        end

        it 'serializes the field correctly' do
          # only 1 record is there, so meh no need to do it outside of yield_documents
          subject.yield_documents do |doc|
            expect(doc['price']).to eq(BigDecimal(price))
          end
        end
      end

      context 'when array of strings is met' do
        let(:array_of_strings) { ['1', '1b', '17', '222'] }
        let(:actual_collection_data) do
          [
            { '_id' => 1, 'rooms' => array_of_strings }
          ]
        end

        it 'serializes the field correctly' do
          # only 1 record is there, so meh no need to do it outside of yield_documents
          subject.yield_documents do |doc|
            expect(doc['rooms']).to eq(array_of_strings)
          end
        end
      end

      context 'when field that needs special serialization is nested in hash' do
        let(:price) { '12.00' }
        let(:actual_collection_data) do
          [
            { '_id' => 1, 'room' => { 'price' => BSON::Decimal128.from_string(price) } }
          ]
        end

        it 'serializes the field correctly' do
          # only 1 record is there, so meh no need to do it outside of yield_documents
          subject.yield_documents do |doc|
            expect(doc['room']['price']).to eq(BigDecimal(price))
          end
        end
      end

      context 'when field that needs special serialization is nested in array' do
        let(:price) { '12.00' }
        let(:actual_collection_data) do
          [
            { '_id' => 1, 'rooms' => [{ 'price' => BSON::Decimal128.from_string(price) }] }
          ]
        end

        it 'serializes the field correctly' do
          # only 1 record is there, so meh no need to do it outside of yield_documents
          subject.yield_documents do |doc|
            expect(doc['rooms'][0]['price']).to eq(BigDecimal(price))
          end
        end
      end
    end

    context 'find field exists (with filter and options) in an active advanced filtering config' do
      it 'calls the mongo client\'s find method with filter and options' do
        expect(actual_collection).to receive(:find).with(filter, options)

        subject.yield_documents
      end
    end

    context 'rules and advanced filtering config are empty' do
      let(:rules) { [] }
      let(:advanced_snippet) { {} }

      it 'calls find without arguments' do
        expect(actual_collection).to receive(:find).with(no_args)

        subject.yield_documents
      end
    end

    context 'rule is present and advanced filtering is empty' do
      let(:advanced_snippet) { {} }

      it 'applies the simple rule' do
        expect(actual_collection).to receive(:find).with(match({ 'name' => 'apple' }))

        subject.yield_documents
      end
    end

    context 'both rules and advanced filtering are present' do
      it 'does not apply the simple rule' do
        expect(actual_collection).to receive(:find).with(filter, options)

        subject.yield_documents
      end
    end

    context 'find field exists (with filter and empty options) in an active advanced filtering config' do
      let(:options) {
        {}
      }

      it 'calls the mongo client find method with filter and empty options' do
        expect(actual_collection).to receive(:find).with(filter, {})

        subject.yield_documents
      end
    end

    context 'find field exists (with filter and nil options) in an active advanced filtering config' do
      let(:options) {
        nil
      }

      it 'calls the mongo client find method with filter and nil options without breaking' do
        expect(actual_collection).to receive(:find).with(filter, {})

        subject.yield_documents
      end
    end

    context 'find field exists (with empty filter and existing options) in an active advanced filtering config' do
      let(:filter) {
        {}
      }

      it 'calls the mongo client fiend method with empty filter and existing options' do
        expect(actual_collection).to receive(:find).with({}, options)

        subject.yield_documents
      end
    end

    context 'find field exists (with nil filter and existing options) in an active advanced filtering config' do
      let(:filter) {
        nil
      }

      it 'calls the mongo client find method with nil and existing options' do
        # nil is also the default value in the mongodb client, so it's ok to pass it
        expect(actual_collection).to receive(:find).with(nil, options)

        subject.yield_documents
      end
    end

    context 'find field exists with empty filter and empty options' do
      let(:find) {
        {
          :filter => {},
          :options => {}
        }
      }

      it 'logs a warning' do
        expect(Utility::Logger).to receive(:warn).with('\'Find\' was specified with an empty filter and empty options.')

        subject.yield_documents
      end
    end

    context 'when aggregate is present' do
      shared_examples_for 'calls aggregate' do |expected_pipeline, expected_options|
        it '' do
          expect(actual_collection).to receive(:aggregate).with(expected_pipeline, expected_options)
          expect(mongo_collection_cursor).to receive(:each)

          # aggregate does not expose this functionality directly (only through pipeline stages)
          expect(mongo_collection_cursor).to_not receive(:skip)
          expect(mongo_collection_cursor).to_not receive(:limit)

          subject.yield_documents
        end
      end

      # necessary to reuse it as parameter for it_behaves_like and let()
      pipeline = [{ '$skip' => 5 }]
      options = { 'batch_size' => 10 }

      let(:pipeline) { pipeline }

      let(:options) { options }

      let(:advanced_snippet) {
        {
          :aggregate => aggregate
        }
      }

      it_behaves_like 'calls aggregate', pipeline, options

      context 'when options are not present' do
        context 'when options are empty' do
          let(:options) { {} }

          it_behaves_like 'calls aggregate', pipeline, {}
        end

        context 'when options are nil' do
          let(:options) { nil }

          it_behaves_like 'calls aggregate', pipeline, {}
        end
      end

      context 'when pipeline is not present' do
        context 'when pipeline is empty' do
          let(:pipeline) { [] }

          it_behaves_like 'calls aggregate', [], options
        end

        context 'when pipeline is nil' do
          let(:pipeline) { nil }

          # still calls aggregate with an empty pipeline. Nil pipeline would lead to the aggregation to crash
          it_behaves_like 'calls aggregate', [], options
        end
      end

      context 'when pipeline and options are nil' do
        let(:pipeline) { nil }
        let(:options) { nil }

        it_behaves_like 'calls aggregate', [], {}

        it 'logs a warning' do
          expect(Utility::Logger).to receive(:warn).with('\'Aggregate\' was specified with an empty pipeline and empty options.')
          expect(mongo_collection_cursor).to receive(:each)

          subject.yield_documents
        end
      end
    end
  end
end
