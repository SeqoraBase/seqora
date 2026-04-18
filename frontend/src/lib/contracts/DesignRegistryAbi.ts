export const DesignRegistryAbi = [
  {
    "type": "constructor",
    "inputs": [
      {
        "name": "baseUri_",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "screening_",
        "type": "address",
        "internalType": "contract IScreeningAttestations"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "SCREENING",
    "inputs": [],
    "outputs": [
      {
        "name": "",
        "type": "address",
        "internalType": "contract IScreeningAttestations"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "balanceOf",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "id",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "balanceOfBatch",
    "inputs": [
      {
        "name": "accounts",
        "type": "address[]",
        "internalType": "address[]"
      },
      {
        "name": "ids",
        "type": "uint256[]",
        "internalType": "uint256[]"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "uint256[]",
        "internalType": "uint256[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "forkRegister",
    "inputs": [
      {
        "name": "params",
        "type": "tuple",
        "internalType": "struct SeqoraTypes.ForkParams",
        "components": [
          {
            "name": "registrant",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "primaryParentTokenId",
            "type": "uint256",
            "internalType": "uint256"
          },
          {
            "name": "additionalParentTokenIds",
            "type": "bytes32[]",
            "internalType": "bytes32[]"
          },
          {
            "name": "canonicalHash",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "ga4ghSeqhash",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "arweaveTx",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "ceramicStreamId",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "royaltyRule",
            "type": "tuple",
            "internalType": "struct SeqoraTypes.RoyaltyRule",
            "components": [
              {
                "name": "recipient",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "bps",
                "type": "uint16",
                "internalType": "uint16"
              },
              {
                "name": "parentSplitBps",
                "type": "uint16",
                "internalType": "uint16"
              }
            ]
          },
          {
            "name": "screeningAttestationUID",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "metadataURI",
            "type": "string",
            "internalType": "string"
          }
        ]
      }
    ],
    "outputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "getDesign",
    "inputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "design",
        "type": "tuple",
        "internalType": "struct SeqoraTypes.Design",
        "components": [
          {
            "name": "canonicalHash",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "ga4ghSeqhash",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "arweaveTx",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "ceramicStreamId",
            "type": "string",
            "internalType": "string"
          },
          {
            "name": "royalty",
            "type": "tuple",
            "internalType": "struct SeqoraTypes.RoyaltyRule",
            "components": [
              {
                "name": "recipient",
                "type": "address",
                "internalType": "address"
              },
              {
                "name": "bps",
                "type": "uint16",
                "internalType": "uint16"
              },
              {
                "name": "parentSplitBps",
                "type": "uint16",
                "internalType": "uint16"
              }
            ]
          },
          {
            "name": "screeningAttestationUID",
            "type": "bytes32",
            "internalType": "bytes32"
          },
          {
            "name": "parentTokenIds",
            "type": "bytes32[]",
            "internalType": "bytes32[]"
          },
          {
            "name": "registrant",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "registeredAt",
            "type": "uint64",
            "internalType": "uint64"
          }
        ]
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isApprovedForAll",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "operator",
        "type": "address",
        "internalType": "address"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "isRegistered",
    "inputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "registered",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "parentsOf",
    "inputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "parents",
        "type": "bytes32[]",
        "internalType": "bytes32[]"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "register",
    "inputs": [
      {
        "name": "registrant",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "canonicalHash",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "ga4ghSeqhash",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "arweaveTx",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "ceramicStreamId",
        "type": "string",
        "internalType": "string"
      },
      {
        "name": "royalty",
        "type": "tuple",
        "internalType": "struct SeqoraTypes.RoyaltyRule",
        "components": [
          {
            "name": "recipient",
            "type": "address",
            "internalType": "address"
          },
          {
            "name": "bps",
            "type": "uint16",
            "internalType": "uint16"
          },
          {
            "name": "parentSplitBps",
            "type": "uint16",
            "internalType": "uint16"
          }
        ]
      },
      {
        "name": "screeningAttestationUID",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "parentTokenIds",
        "type": "bytes32[]",
        "internalType": "bytes32[]"
      }
    ],
    "outputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "safeBatchTransferFrom",
    "inputs": [
      {
        "name": "from",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "ids",
        "type": "uint256[]",
        "internalType": "uint256[]"
      },
      {
        "name": "values",
        "type": "uint256[]",
        "internalType": "uint256[]"
      },
      {
        "name": "data",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "safeTransferFrom",
    "inputs": [
      {
        "name": "from",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "id",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "value",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "data",
        "type": "bytes",
        "internalType": "bytes"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "setApprovalForAll",
    "inputs": [
      {
        "name": "operator",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "approved",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "outputs": [],
    "stateMutability": "nonpayable"
  },
  {
    "type": "function",
    "name": "supportsInterface",
    "inputs": [
      {
        "name": "interfaceId",
        "type": "bytes4",
        "internalType": "bytes4"
      }
    ],
    "outputs": [
      {
        "name": "supported",
        "type": "bool",
        "internalType": "bool"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "function",
    "name": "uri",
    "inputs": [
      {
        "name": "",
        "type": "uint256",
        "internalType": "uint256"
      }
    ],
    "outputs": [
      {
        "name": "",
        "type": "string",
        "internalType": "string"
      }
    ],
    "stateMutability": "view"
  },
  {
    "type": "event",
    "name": "ApprovalForAll",
    "inputs": [
      {
        "name": "account",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "operator",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "approved",
        "type": "bool",
        "indexed": false,
        "internalType": "bool"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "DesignForked",
    "inputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "parentTokenIds",
        "type": "bytes32[]",
        "indexed": false,
        "internalType": "bytes32[]"
      },
      {
        "name": "registrant",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "DesignRegistered",
    "inputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      },
      {
        "name": "registrant",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "canonicalHash",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      },
      {
        "name": "ga4ghSeqhash",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      },
      {
        "name": "screeningAttestationUID",
        "type": "bytes32",
        "indexed": false,
        "internalType": "bytes32"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "TransferBatch",
    "inputs": [
      {
        "name": "operator",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "from",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "ids",
        "type": "uint256[]",
        "indexed": false,
        "internalType": "uint256[]"
      },
      {
        "name": "values",
        "type": "uint256[]",
        "indexed": false,
        "internalType": "uint256[]"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "TransferSingle",
    "inputs": [
      {
        "name": "operator",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "from",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "to",
        "type": "address",
        "indexed": true,
        "internalType": "address"
      },
      {
        "name": "id",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      },
      {
        "name": "value",
        "type": "uint256",
        "indexed": false,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "event",
    "name": "URI",
    "inputs": [
      {
        "name": "value",
        "type": "string",
        "indexed": false,
        "internalType": "string"
      },
      {
        "name": "id",
        "type": "uint256",
        "indexed": true,
        "internalType": "uint256"
      }
    ],
    "anonymous": false
  },
  {
    "type": "error",
    "name": "AlreadyRegistered",
    "inputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "AttestationInvalid",
    "inputs": [
      {
        "name": "attestationUID",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "BpsOutOfRange",
    "inputs": [
      {
        "name": "bps",
        "type": "uint16",
        "internalType": "uint16"
      }
    ]
  },
  {
    "type": "error",
    "name": "CanonicalHashMismatch",
    "inputs": [
      {
        "name": "expected",
        "type": "bytes32",
        "internalType": "bytes32"
      },
      {
        "name": "actual",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC1155InsufficientBalance",
    "inputs": [
      {
        "name": "sender",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "balance",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "needed",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "tokenId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC1155InvalidApprover",
    "inputs": [
      {
        "name": "approver",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC1155InvalidArrayLength",
    "inputs": [
      {
        "name": "idsLength",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "valuesLength",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC1155InvalidOperator",
    "inputs": [
      {
        "name": "operator",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC1155InvalidReceiver",
    "inputs": [
      {
        "name": "receiver",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC1155InvalidSender",
    "inputs": [
      {
        "name": "sender",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "ERC1155MissingApprovalForAll",
    "inputs": [
      {
        "name": "operator",
        "type": "address",
        "internalType": "address"
      },
      {
        "name": "owner",
        "type": "address",
        "internalType": "address"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidParent",
    "inputs": [
      {
        "name": "parentTokenId",
        "type": "bytes32",
        "internalType": "bytes32"
      }
    ]
  },
  {
    "type": "error",
    "name": "InvalidRoyaltyRecipient",
    "inputs": []
  },
  {
    "type": "error",
    "name": "NoParentsForFork",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ReentrancyGuardReentrantCall",
    "inputs": []
  },
  {
    "type": "error",
    "name": "SelfParent",
    "inputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "StringTooLong",
    "inputs": [
      {
        "name": "supplied",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "max",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "TooManyParents",
    "inputs": [
      {
        "name": "supplied",
        "type": "uint256",
        "internalType": "uint256"
      },
      {
        "name": "max",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "UnknownToken",
    "inputs": [
      {
        "name": "tokenId",
        "type": "uint256",
        "internalType": "uint256"
      }
    ]
  },
  {
    "type": "error",
    "name": "UseForkRegister",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ZeroAddress",
    "inputs": []
  },
  {
    "type": "error",
    "name": "ZeroValue",
    "inputs": []
  }
] as const;
